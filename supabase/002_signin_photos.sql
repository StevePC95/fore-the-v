-- Fore the V: sign-in (group code + who you are), dop logging by the 8 on tour,
-- and a private shared photo store.
-- Run once in Supabase: SQL Editor > New query > paste all > Run.
-- Before running: Authentication > Sign In / Providers > turn ON "Allow anonymous sign-ins".
-- After running: set the group code with the one-liner at the bottom.

-- 1. Who's who ---------------------------------------------------------------
create table if not exists public.players (
  id       text primary key,
  name     text not null,          -- full name shown in the sign-in list
  short    text not null,          -- tour name: Steve, Nic, Jay...
  team     text check (team in ('in','co')),  -- set = on the current tour (Tour V); null = past tourist
  is_admin boolean not null default false,
  sort     int not null default 100
);
alter table public.players enable row level security;
drop policy if exists "Anyone can read players" on public.players;
create policy "Anyone can read players" on public.players for select using (true);

insert into public.players (id, name, short, team, is_admin, sort) values
  ('steve',   'Stephen Coombe',    'Steve',   'in', true,  1),
  ('nic',     'Nicolas Finn',      'Nic',     'in', false, 2),
  ('luke',    'Luke Gibbon',       'Luke',    'in', false, 3),
  ('brandon', 'Brandon Wiesner',   'Brandon', 'in', false, 4),
  ('guy',     'Guy Moody',         'Guy',     'co', false, 5),
  ('mitch',   'Mitch Cason',       'Mitch',   'co', false, 6),
  ('jay',     'Jason de Klerk',    'Jay',     'co', false, 7),
  ('rich',    'Richard Le Roux',   'Rich',    'co', false, 8),
  ('dylan',   'Dylan de Charmoy',  'Dylan',   null, false, 20),
  ('joel',    'Joel Shepherd',     'Joel',    null, false, 21),
  ('sheldon', 'Sheldon Bruin',     'Sheldon', null, false, 22),
  ('george',  'George van Vuuren', 'George',  null, false, 23),
  ('guyk',    'Guy Kirby',         'Guy K',   null, false, 24),
  ('murray',  'Murray Gibbon',     'Murray',  null, false, 25),
  ('josh',    'Joshua Campbell',   'Josh',    null, false, 26),
  ('ricky',   'Ricky Hughes',      'Ricky',   null, false, 27)
on conflict (id) do update set name = excluded.name, short = excluded.short, team = excluded.team,
  is_admin = excluded.is_admin, sort = excluded.sort;

-- 2. Signed-in phones ----------------------------------------------------------
create table if not exists public.members (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  player_id    text references public.players (id),
  display_name text not null,
  tour_access  boolean not null default false,   -- true = one of the 8 on Tour V (can log dops)
  created_at   timestamptz not null default now()
);
alter table public.members enable row level security;
drop policy if exists "Read your own membership" on public.members;
create policy "Read your own membership" on public.members for select to authenticated using (user_id = auth.uid());

alter table public.tour_secret add column if not exists group_code text;
update public.tour_secret set group_code = coalesce(group_code, 'CHANGE-ME-TOO') where id = 1;

create or replace function public.ftv_is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where user_id = auth.uid());
$$;

create or replace function public.ftv_check_group(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_code is not null and p_code = (select group_code from tour_secret where id = 1);
$$;

create or replace function public.ftv_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('player_id', m.player_id, 'name', m.display_name, 'short', coalesce(p.short, m.display_name),
                            'team', p.team, 'tour_access', m.tour_access, 'is_admin', coalesce(p.is_admin, false))
  from members m left join players p on p.id = m.player_id
  where m.user_id = auth.uid();
$$;

create or replace function public.ftv_join(p_code text, p_player text, p_name text default null, p_tour_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pl players; tour_ok boolean := false; nm text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not ftv_check_group(p_code) then raise exception 'bad_code' using errcode = '28P01'; end if;
  if p_player is not null then
    select * into pl from players where id = p_player;
    if not found then raise exception 'bad_player'; end if;
    if pl.team is not null then
      if p_tour_code is null or p_tour_code <> (select pin from tour_secret where id = 1) then
        raise exception 'bad_tour_code' using errcode = '28P01';
      end if;
      tour_ok := true;
    end if;
    nm := pl.name;
  else
    nm := nullif(trim(coalesce(p_name, '')), '');
    if nm is null then raise exception 'bad_name'; end if;
  end if;
  insert into members (user_id, player_id, display_name, tour_access)
  values (auth.uid(), p_player, nm, tour_ok)
  on conflict (user_id) do update set player_id = excluded.player_id, display_name = excluded.display_name,
    tour_access = excluded.tour_access;
  return ftv_me();
end $$;

-- 3. Dops: only the 8 on tour can log, and the logger is the witness --------------
alter table public.dops add column if not exists logged_by uuid;

create or replace function public.ftv_log_dop(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  m members; wteam text; dteam text;
  d text := p->>'drinker'; k text := p->>'kind';
  is_prac boolean := now() < timestamptz '2026-11-06 12:00:00+02';
  new_id uuid;
begin
  select * into m from members where user_id = auth.uid();
  if not found or not m.tour_access then raise exception 'not_on_tour' using errcode = '42501'; end if;
  select team into wteam from players where id = m.player_id;
  select team into dteam from players where id = d;
  if dteam is null then raise exception 'bad_player'; end if;
  if dteam = wteam then raise exception 'bad_witness'; end if;
  if k not in ('fri1','fri2','tee') then raise exception 'bad_kind'; end if;
  if k = 'tee' and ((p->>'day') not in ('fri','sat') or (p->>'hole')::int not between 1 and 9) then
    raise exception 'bad_hole';
  end if;
  insert into dops (drinker, team, kind, pts, witness, practice, at_ms, day, hole, secs, gulps, tee_key, logged_by)
  values (
    d, dteam, k, case k when 'fri2' then 2 else 1 end, m.player_id, is_prac,
    (extract(epoch from now()) * 1000)::bigint,
    case when k = 'tee' then p->>'day' end,
    case when k = 'tee' then (p->>'hole')::int end,
    nullif(p->>'secs', '')::numeric, nullif(p->>'gulps', '')::int,
    case when k = 'tee'
      then (case when is_prac then 'p-' else '' end) || 'tee-' || (p->>'day') || '-' || (p->>'hole') || '-' || d end,
    auth.uid()
  ) returning id into new_id;
  return new_id;
end $$;

create or replace function public.ftv_delete_dop(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m members; adm boolean;
begin
  select * into m from members where user_id = auth.uid();
  if not found or not m.tour_access then raise exception 'not_on_tour' using errcode = '42501'; end if;
  select is_admin into adm from players where id = m.player_id;
  delete from dops where id = p_id and (logged_by = auth.uid() or coalesce(adm, false));
end $$;

create or replace function public.ftv_clear_practice() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from members where user_id = auth.uid() and tour_access) then
    raise exception 'not_on_tour' using errcode = '42501';
  end if;
  delete from dops where practice;
end $$;

-- The old PIN-only functions are retired.
revoke execute on function public.log_dop(text, jsonb)   from anon, authenticated;
revoke execute on function public.delete_dop(text, uuid) from anon, authenticated;
revoke execute on function public.clear_practice(text)   from anon, authenticated;

-- 4. Photos (private: signed-in members only) ---------------------------------
create table if not exists public.photos (
  id          uuid primary key default gen_random_uuid(),
  path        text not null unique,
  thumb_path  text not null,
  album       text not null default 'general',
  uploaded_by uuid not null default auth.uid(),
  player_id   text,
  added_by    text,
  width       int,
  height      int,
  created_at  timestamptz not null default now()
);
alter table public.photos enable row level security;
drop policy if exists "Members see photos" on public.photos;
drop policy if exists "Members add photos" on public.photos;
drop policy if exists "Remove your own photos" on public.photos;
create policy "Members see photos" on public.photos for select to authenticated using (public.ftv_is_member());
create policy "Members add photos" on public.photos for insert to authenticated
  with check (public.ftv_is_member() and uploaded_by = auth.uid());
create policy "Remove your own photos" on public.photos for delete to authenticated using (uploaded_by = auth.uid());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 10485760, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "FTV members read photos" on storage.objects;
drop policy if exists "FTV members upload photos" on storage.objects;
create policy "FTV members read photos" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and public.ftv_is_member());
create policy "FTV members upload photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and public.ftv_is_member());

grant execute on function public.ftv_check_group(text) to anon, authenticated;
grant execute on function public.ftv_me() to authenticated;
grant execute on function public.ftv_join(text, text, text, text) to authenticated;
grant execute on function public.ftv_log_dop(jsonb) to authenticated;
grant execute on function public.ftv_delete_dop(uuid) to authenticated;
grant execute on function public.ftv_clear_practice() to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.photos;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Now set the group code everyone uses to get in (run separately, change it):
--   update public.tour_secret set group_code = 'fore-the-boys' where id = 1;
-- The Tour V code is your existing dop PIN; the 8 on tour enter it once at sign-in.
