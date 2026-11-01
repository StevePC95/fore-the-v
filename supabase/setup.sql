-- Fore the V: shared dop log.
-- Run this once in Supabase: SQL Editor > New query > paste > Run.
-- Then set the real tour PIN with the one-liner at the bottom (run it in the
-- SQL Editor only; don't save the real PIN in this file, the repo is public).

create extension if not exists pgcrypto;

-- The dops ----------------------------------------------------------------
create table if not exists public.dops (
  id         uuid primary key default gen_random_uuid(),
  drinker    text not null,
  team       text not null check (team in ('in','co')),
  kind       text not null check (kind in ('fri1','fri2','tee')),
  pts        int  not null,
  witness    text not null,
  practice   boolean not null default false,
  at_ms      bigint not null,
  day        text check (day in ('fri','sat')),
  hole       int  check (hole between 1 and 9),
  secs       numeric,
  gulps      int,
  tee_key    text unique,            -- one tee-box down-down per man, per hole, per day
  created_at timestamptz not null default now()
);

alter table public.dops enable row level security;
drop policy if exists "Anyone can read dops" on public.dops;
create policy "Anyone can read dops" on public.dops for select using (true);
-- No insert/update/delete policies: writes only happen through the PIN functions below.

-- The tour PIN (unreadable from the website) --------------------------------
create table if not exists public.tour_secret (
  id  int primary key default 1 check (id = 1),
  pin text not null
);
alter table public.tour_secret enable row level security;
insert into public.tour_secret (id, pin) values (1, 'CHANGE-ME') on conflict (id) do nothing;

create or replace function public.ftv_check_pin(p_pin text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_pin is null or p_pin <> (select pin from tour_secret where id = 1) then
    raise exception 'bad_pin' using errcode = '28P01';
  end if;
end $$;
revoke all on function public.ftv_check_pin(text) from public, anon, authenticated;

-- Log a dop -----------------------------------------------------------------
create or replace function public.log_dop(p_pin text, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  players  jsonb := '{"steve":"in","nic":"in","luke":"in","brandon":"in","guy":"co","mitch":"co","jay":"co","rich":"co"}';
  d        text  := p->>'drinker';
  w        text  := p->>'witness';
  k        text  := p->>'kind';
  is_prac  boolean := now() < timestamptz '2026-11-06 12:00:00+02';
  new_id   uuid;
begin
  perform ftv_check_pin(p_pin);
  if players->>d is null or players->>w is null then raise exception 'bad_player'; end if;
  if players->>d = players->>w then raise exception 'bad_witness'; end if;
  if k not in ('fri1','fri2','tee') then raise exception 'bad_kind'; end if;
  if k = 'tee' and ((p->>'day') not in ('fri','sat') or (p->>'hole')::int not between 1 and 9) then
    raise exception 'bad_hole';
  end if;

  insert into dops (drinker, team, kind, pts, witness, practice, at_ms, day, hole, secs, gulps, tee_key)
  values (
    d, players->>d, k,
    case k when 'fri2' then 2 else 1 end,
    w, is_prac,
    (extract(epoch from now()) * 1000)::bigint,
    case when k = 'tee' then p->>'day' end,
    case when k = 'tee' then (p->>'hole')::int end,
    nullif(p->>'secs', '')::numeric,
    nullif(p->>'gulps', '')::int,
    case when k = 'tee'
      then (case when is_prac then 'p-' else '' end) || 'tee-' || (p->>'day') || '-' || (p->>'hole') || '-' || d
    end
  )
  returning id into new_id;
  return new_id;
end $$;

-- Remove one dop ------------------------------------------------------------
create or replace function public.delete_dop(p_pin text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform ftv_check_pin(p_pin);
  delete from dops where id = p_id;
end $$;

-- Clear practice dops -------------------------------------------------------
create or replace function public.clear_practice(p_pin text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform ftv_check_pin(p_pin);
  delete from dops where practice;
end $$;

revoke all on function public.log_dop(text, jsonb)     from public;
revoke all on function public.delete_dop(text, uuid)   from public;
revoke all on function public.clear_practice(text)     from public;
grant execute on function public.log_dop(text, jsonb)   to anon, authenticated;
grant execute on function public.delete_dop(text, uuid) to anon, authenticated;
grant execute on function public.clear_practice(text)   to anon, authenticated;

-- Live updates on everyone's phone ------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.dops;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Now set the real PIN (run separately, change 1234 to your PIN):
--   update public.tour_secret set pin = '1234' where id = 1;
