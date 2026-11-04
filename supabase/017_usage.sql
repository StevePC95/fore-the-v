-- 017: App usage tracking + stats for Steve's Desk.
-- app_events: one row each time someone opens a page (or opens the app).
-- Nobody can read or write the table directly; phones log through ftv_track(),
-- and only Steve (is_admin) can read the summary through ftv_usage_stats().

create table if not exists public.app_events (
  id bigserial primary key,
  player_id text not null,
  view text not null,
  created_at timestamptz not null default now()
);
create index if not exists app_events_created_idx on public.app_events (created_at);
create index if not exists app_events_player_idx on public.app_events (player_id, created_at);
alter table public.app_events enable row level security;
revoke all on public.app_events from anon, authenticated;

-- Log a batch of page views from this phone. p_events = [{"v":"bookie","t":"2026-11-06T10:00:00Z"}, ...]
create or replace function public.ftv_track(p_events jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare pid text;
begin
  select player_id into pid from members where user_id = auth.uid();
  if pid is null or jsonb_typeof(p_events) <> 'array' then return; end if;
  insert into app_events (player_id, view, created_at)
  select pid, left(e->>'v', 30),
         least(now(), greatest(now() - interval '1 day', coalesce((e->>'t')::timestamptz, now())))
  from (select value e from jsonb_array_elements(p_events) limit 60) x
  where coalesce(e->>'v', '') ~ '^[a-z0-9_-]{1,30}$';
exception when others then return; -- tracking must never break the app
end $$;
grant execute on function public.ftv_track(jsonb) to authenticated;

-- Everything the Desk's Usage card shows. Test profiles left out.
create or replace function public.ftv_usage_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; tz text := 'Africa/Johannesburg';
begin
  if not ftv_is_admin() then raise exception 'not_allowed' using errcode = '42501'; end if;
  with real as (select id from players where not coalesce(is_test, false)),
  ev as (select * from app_events where player_id in (select id from real)),
  bt as (select * from bets where player_id in (select id from real)),
  cs as (select * from casino_spins where player_id in (select id from real)),
  ppl as (
    select p.id, coalesce(p.short, p.name) as name, p.team, p.sort,
      (select max(created_at) from ev where ev.player_id = p.id) as last_seen,
      (select count(*) from ev where ev.player_id = p.id) as views,
      (select count(*) from ev where ev.player_id = p.id and (created_at at time zone tz)::date = (now() at time zone tz)::date) as views_today,
      (select view from ev where ev.player_id = p.id and view <> 'open' group by view order by count(*) desc limit 1) as fav,
      (select count(*) from bt where bt.player_id = p.id) as bets,
      (select coalesce(sum(stake), 0) from bt where bt.player_id = p.id) as staked,
      (select count(distinct coalesce(spin_id, id)) from cs where cs.player_id = p.id) as spins,
      (select count(*) from dop_videos d where d.drinker = p.id) as fullies,
      (select count(*) from photos ph where ph.player_id = p.id) as photos
    from players p where p.id in (select id from real)
      and (p.team is not null or exists (select 1 from members m where m.player_id = p.id))
  )
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'bets', (select count(*) from bt),
      'staked', (select coalesce(sum(stake), 0) from bt),
      'spins', (select count(distinct coalesce(spin_id, id)) from cs),
      'casino_staked', (select coalesce(sum(stake), 0) from cs),
      'house_casino', (select coalesce(sum(stake - coalesce(payout, 0)), 0) from cs),
      'fullies', (select count(*) from dop_videos),
      'photos', (select count(*) from photos),
      'pitches', (select count(*) from market_suggestions where player_id in (select id from real)),
      'buyins', (select count(*) from bookie_joins where player_id in (select id from real)),
      'views', (select count(*) from ev),
      'tracked_since', (select min(created_at) from ev),
      'active_today', (select count(distinct player_id) from ev where (created_at at time zone tz)::date = (now() at time zone tz)::date),
      'active_hour', (select count(distinct player_id) from ev where created_at > now() - interval '1 hour')
    ),
    'pages', coalesce((select jsonb_agg(x order by x.n desc) from (
      select view as v, count(*) as n, count(distinct player_id) as people from ev where view <> 'open' group by view) x), '[]'::jsonb),
    'hours', coalesce((select jsonb_agg(x order by x.h) from (
      select extract(hour from created_at at time zone tz)::int as h, count(*) as n from ev group by 1) x), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(x order by x.d) from (
      select (created_at at time zone tz)::date as d, count(*) as n, count(distinct player_id) as people
      from ev where created_at > now() - interval '7 days' group by 1) x), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(to_jsonb(ppl) order by ppl.last_seen desc nulls last, ppl.sort) from ppl), '[]'::jsonb)
  ) into r;
  return r;
end $$;
grant execute on function public.ftv_usage_stats() to authenticated;
