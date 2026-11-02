-- Fore the V: Steve's test profile ("Steve Test").
-- Run once in Supabase: SQL Editor > New query > paste all > Run. (Needs 010 first.) Safe to run again.
--  * Only reachable from Steve's own phone: Account > "Switch to test profile". Nobody can pick it at sign-in.
--  * It behaves like a regular punter: not an admin, no team, no scoring, but it gets a Bookie wallet.
--  * Its bets, spins and pitches are hidden from everyone except the test profile itself and Steve.
--  * "Reset test profile" wipes its bets, spins, pitches (and any market made from its pitches) back to R1,000,000.

alter table public.players add column if not exists is_test boolean not null default false;
alter table public.members add column if not exists test_of text;            -- the real player this phone switched from
alter table public.members add column if not exists test_prev_access boolean;

insert into public.players (id, name, short, team, is_admin, sort, is_test)
values ('steve_test', 'Steve Test', 'Steve T', null, false, 99, true)
on conflict (id) do update set name = excluded.name, short = excluded.short, team = null, is_admin = false, is_test = true;

insert into public.bookie_joins (player_id) values ('steve_test') on conflict do nothing;

-- Nobody can sign in as a test player directly: only by switching from an admin.
create or replace function public.ftv_guard_test_member() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from players where id = new.player_id and is_test)
     and not exists (select 1 from players where id = new.test_of and is_admin) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from players where id = new.player_id and is_test) then
    new.test_of := null; new.test_prev_access := null;     -- a real sign-in clears any test link
  end if;
  return new;
end $$;
drop trigger if exists ftv_guard_test_member on public.members;
create trigger ftv_guard_test_member before insert or update on public.members
  for each row execute function public.ftv_guard_test_member();

-- Who's signed in: now also says whether this phone is on the test profile.
create or replace function public.ftv_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('player_id', m.player_id, 'name', m.display_name, 'short', coalesce(p.short, m.display_name),
                            'team', p.team, 'tour_access', m.tour_access, 'is_admin', coalesce(p.is_admin, false),
                            'is_captain', coalesce(p.is_captain, false),
                            'is_test', coalesce(p.is_test, false), 'test_of', m.test_of)
  from members m left join players p on p.id = m.player_id
  where m.user_id = auth.uid();
$$;

create or replace function public.ftv_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members m join players p on p.id = m.player_id where m.user_id = auth.uid() and p.is_admin);
$$;
grant execute on function public.ftv_is_admin() to authenticated;

create or replace function public.ftv_my_player() returns text
language sql stable security definer set search_path = public as $$
  select player_id from members where user_id = auth.uid();
$$;
grant execute on function public.ftv_my_player() to authenticated;

-- Switch this phone between Steve and Steve (test).
create or replace function public.ftv_switch_test() returns jsonb
language plpgsql security definer set search_path = public as $$
declare m members; p players;
begin
  select * into m from members where user_id = auth.uid();
  if not found then raise exception 'not_allowed' using errcode = '42501'; end if;
  if m.test_of is not null then                                  -- back to the real profile
    update members set player_id = m.test_of, display_name = (select name from players where id = m.test_of),
                       tour_access = coalesce(m.test_prev_access, false), test_of = null, test_prev_access = null
     where user_id = auth.uid();
  else
    select * into p from players where id = m.player_id;
    if not coalesce(p.is_admin, false) then raise exception 'not_allowed' using errcode = '42501'; end if;
    update members set test_of = m.player_id, test_prev_access = m.tour_access, player_id = 'steve_test',
                       display_name = 'Steve Test', tour_access = false
     where user_id = auth.uid();
    insert into bookie_joins (player_id) values ('steve_test') on conflict do nothing;
  end if;
  return ftv_me();
end $$;
revoke all on function public.ftv_switch_test() from public;
grant execute on function public.ftv_switch_test() to authenticated;

-- Wipe the test profile's Bookie history (from either Steve or the test profile).
create or replace function public.ftv_test_reset() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (ftv_is_admin() or exists (select 1 from members where user_id = auth.uid() and test_of is not null)) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from markets where id in (select market_id from market_suggestions where player_id in (select id from players where is_test) and market_id is not null);
  delete from market_suggestions where player_id in (select id from players where is_test);
  delete from bets where player_id in (select id from players where is_test);
  delete from casino_spins where player_id in (select id from players where is_test);
end $$;
revoke all on function public.ftv_test_reset() from public;
grant execute on function public.ftv_test_reset() to authenticated;

-- Hide the test profile's activity from everyone except itself and Steve.
create or replace function public.ftv_can_see(p_player text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from players where id = p_player and is_test)
      or p_player = ftv_my_player()
      or ftv_is_admin();
$$;
grant execute on function public.ftv_can_see(text) to authenticated;

drop policy if exists "Members read bets" on public.bets;
drop policy if exists "Members read spins" on public.casino_spins;
drop policy if exists "Members read suggestions" on public.market_suggestions;
create policy "Members read bets" on public.bets for select to authenticated
  using (exists (select 1 from members where user_id = auth.uid()) and ftv_can_see(player_id));
create policy "Members read spins" on public.casino_spins for select to authenticated
  using (exists (select 1 from members where user_id = auth.uid()) and ftv_can_see(player_id));
create policy "Members read suggestions" on public.market_suggestions for select to authenticated
  using (exists (select 1 from members where user_id = auth.uid()) and ftv_can_see(player_id));

create or replace function public.ftv_wallets()
returns table (player_id text, short text, team text, balance bigint, inplay bigint)
language sql stable security definer set search_path = public as $$
  select p.id, p.short, p.team, ftv_balance(p.id),
         coalesce((select sum(b.stake) from bets b where b.player_id = p.id and b.payout is null), 0)
  from players p
  where (p.team is not null or exists (select 1 from bookie_joins j where j.player_id = p.id))
    and (not p.is_test or p.id = ftv_my_player())
  order by p.sort;
$$;
grant execute on function public.ftv_wallets() to authenticated;

-- Check: the test profile exists and has a wallet.
select id, name, is_test, ftv_balance(id) from public.players where is_test;
