-- Fore the V: live scoring.
-- Run once in Supabase: SQL Editor > New query > paste all > Run. (Needs 003 and 004 first.)
--  * Anyone can watch the scores and the leaderboard.
--  * Only phones signed in with the Tour V code can enter or correct scores and Wolf calls.
--  * A captain or Steve locks a day once it matches the paper cards; after that only Steve can change it.

create table if not exists public.scores (
  day        text not null check (day in ('fri','sat')),
  hole       int  not null check (hole between 1 and 18),
  player_id  text not null references public.players (id),
  points     int  not null check (points between 0 and 9),   -- Stableford points, full handicap
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (day, hole, player_id)
);

create table if not exists public.wolf_calls (
  day        text not null check (day in ('fri','sat')),
  fourball   int  not null check (fourball in (1, 2)),
  hole       int  not null check (hole between 2 and 18 and hole <> 10),
  call       text not null check (call in ('blind','lone','partner')),
  partner    text references public.players (id),
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (day, fourball, hole)
);

create table if not exists public.day_locks (
  day       text primary key check (day in ('fri','sat')),
  locked    boolean not null default false,
  locked_by text,
  locked_at timestamptz
);

alter table public.scores     enable row level security;
alter table public.wolf_calls enable row level security;
alter table public.day_locks  enable row level security;
drop policy if exists "Anyone can read scores" on public.scores;
drop policy if exists "Anyone can read wolf calls" on public.wolf_calls;
drop policy if exists "Anyone can read day locks" on public.day_locks;
create policy "Anyone can read scores"     on public.scores     for select using (true);
create policy "Anyone can read wolf calls" on public.wolf_calls for select using (true);
create policy "Anyone can read day locks"  on public.day_locks  for select using (true);

-- Who may write: the 8 with the Tour V code. Locked days: Steve only.
create or replace function public.ftv_scorer(p_day text) returns players
language plpgsql stable security definer set search_path = public as $$
declare me players;
begin
  select pl.* into me from members m join players pl on pl.id = m.player_id
   where m.user_id = auth.uid() and m.tour_access;
  if not found then raise exception 'not_allowed' using errcode = '42501'; end if;
  if coalesce((select locked from day_locks where day = p_day), false) and not me.is_admin then
    raise exception 'day_locked';
  end if;
  return me;
end $$;
revoke all on function public.ftv_scorer(text) from public, anon, authenticated;

create or replace function public.ftv_set_score(p_day text, p_hole int, p_player text, p_points int) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ftv_scorer(p_day);
  if not exists (select 1 from players where id = p_player and team is not null) then raise exception 'bad_player'; end if;
  if p_points is null then
    delete from scores where day = p_day and hole = p_hole and player_id = p_player;
  else
    insert into scores (day, hole, player_id, points, updated_by, updated_at)
    values (p_day, p_hole, p_player, p_points, me.short, now())
    on conflict (day, hole, player_id) do update
      set points = excluded.points, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  end if;
end $$;

create or replace function public.ftv_set_wolf_call(p_day text, p_fb int, p_hole int, p_call text, p_partner text) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ftv_scorer(p_day);
  if p_call is null then
    delete from wolf_calls where day = p_day and fourball = p_fb and hole = p_hole;
  else
    insert into wolf_calls (day, fourball, hole, call, partner, updated_by, updated_at)
    values (p_day, p_fb, p_hole, p_call, case when p_call = 'partner' then p_partner end, me.short, now())
    on conflict (day, fourball, hole) do update
      set call = excluded.call, partner = excluded.partner, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  end if;
end $$;

create or replace function public.ftv_lock_day(p_day text, p_locked boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  select pl.* into me from members m join players pl on pl.id = m.player_id
   where m.user_id = auth.uid() and m.tour_access;
  if not found or not (me.is_admin or (me.is_captain and p_locked)) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  insert into day_locks (day, locked, locked_by, locked_at) values (p_day, p_locked, me.short, now())
  on conflict (day) do update set locked = excluded.locked, locked_by = excluded.locked_by, locked_at = excluded.locked_at;
end $$;

revoke all on function public.ftv_set_score(text, int, text, int) from public;
revoke all on function public.ftv_set_wolf_call(text, int, int, text, text) from public;
revoke all on function public.ftv_lock_day(text, boolean) from public;
grant execute on function public.ftv_set_score(text, int, text, int) to authenticated;
grant execute on function public.ftv_set_wolf_call(text, int, int, text, text) to authenticated;
grant execute on function public.ftv_lock_day(text, boolean) to authenticated;

do $$ begin alter publication supabase_realtime add table public.scores;     exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.wolf_calls; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.day_locks;  exception when duplicate_object then null; end $$;
