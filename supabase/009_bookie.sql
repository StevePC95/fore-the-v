-- Fore the V: The Bookie (prediction market, fake money).
-- Run once in Supabase: SQL Editor > New query > paste all > Run. (Needs 002 first.) Safe to run again.
--  * The 8 on Tour V each start with R1,000,000 of fake money.
--  * Steve posts markets (a question + options), closes betting and posts the answer.
--  * Payouts are pari-mutuel (tote): everything staked on a market goes into one pot,
--    and the people who backed the right answer split it in proportion to what they staked.
--    Nobody backed the winner, or the market is voided = everyone gets their stake back.
--  * Balance = R1,000,000 - everything staked + everything paid out. Most money at the end wins.
--  * Every bet is checked here, not in the phone: market still open, enough money, one of the 8.

create table if not exists public.markets (
  id         uuid primary key default gen_random_uuid(),
  question   text not null check (length(trim(question)) between 3 and 160),
  detail     text check (length(detail) <= 400),
  options    text[] not null check (cardinality(options) between 2 and 10),
  closes_at  timestamptz,                              -- betting stops here (null = Steve closes it by hand)
  status     text not null default 'open' check (status in ('open','closed','settled','void')),
  winner     int,                                      -- index into options (0-based) once settled
  seed       text unique,                              -- starter markets only
  created_by text,
  created_at timestamptz not null default now(),
  settled_at timestamptz
);

create table if not exists public.bets (
  id         uuid primary key default gen_random_uuid(),
  market_id  uuid not null references public.markets (id) on delete cascade,
  player_id  text not null references public.players (id),
  option     int  not null check (option >= 0),
  stake      bigint not null check (stake > 0),
  payout     bigint,                                   -- filled in when the market is settled or voided
  created_at timestamptz not null default now()
);
create index if not exists bets_market_idx on public.bets (market_id);
create index if not exists bets_player_idx on public.bets (player_id);

-- Read: any signed-in member (past tourists can watch and heckle). Writes only through the functions below.
alter table public.markets enable row level security;
alter table public.bets    enable row level security;
drop policy if exists "Members read markets" on public.markets;
drop policy if exists "Members read bets" on public.bets;
create policy "Members read markets" on public.markets for select to authenticated
  using (exists (select 1 from members where user_id = auth.uid()));
create policy "Members read bets" on public.bets for select to authenticated
  using (exists (select 1 from members where user_id = auth.uid()));

-- Helpers --------------------------------------------------------------------
create or replace function public.ftv_bookie_me() returns players
language plpgsql stable security definer set search_path = public as $$
declare me players;
begin
  select pl.* into me from members m join players pl on pl.id = m.player_id where m.user_id = auth.uid();
  if not found then raise exception 'not_allowed' using errcode = '42501'; end if;
  return me;
end $$;
revoke all on function public.ftv_bookie_me() from public, anon, authenticated;

create or replace function public.ftv_balance(p_player text) returns bigint
language sql stable security definer set search_path = public as $$
  select 1000000 - coalesce(sum(stake), 0) + coalesce(sum(payout), 0) from bets where player_id = p_player;
$$;
grant execute on function public.ftv_balance(text) to authenticated;

-- Place a bet -----------------------------------------------------------------
create or replace function public.ftv_bet(p_market uuid, p_option int, p_stake bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare me players; mk markets; bal bigint;
begin
  me := ftv_bookie_me();
  if me.team is null then raise exception 'not_on_tour'; end if;
  if p_stake is null or p_stake < 1 then raise exception 'bad_stake'; end if;
  perform pg_advisory_xact_lock(hashtext('ftv_bet_' || me.id));          -- no double-spending from two phones
  select * into mk from markets where id = p_market for update;
  if not found then raise exception 'no_market'; end if;
  if mk.status <> 'open' or (mk.closes_at is not null and mk.closes_at <= now()) then raise exception 'closed'; end if;
  if p_option < 0 or p_option >= cardinality(mk.options) then raise exception 'bad_option'; end if;
  bal := ftv_balance(me.id);
  if p_stake > bal then raise exception 'skint'; end if;
  insert into bets (market_id, player_id, option, stake) values (p_market, me.id, p_option, p_stake);
  return bal - p_stake;
end $$;

-- Steve: create or edit a market (options can only change before anyone bets) -------------
create or replace function public.ftv_market_save(p_id uuid, p_question text, p_detail text, p_options text[], p_closes timestamptz)
returns uuid language plpgsql security definer set search_path = public as $$
declare me players; mk markets; opts text[]; nid uuid;
begin
  me := ftv_bookie_me();
  if not me.is_admin then raise exception 'not_allowed' using errcode = '42501'; end if;
  select array_agg(trim(o)) into opts from unnest(p_options) o where length(trim(o)) > 0;
  if cardinality(opts) < 2 then raise exception 'need_two_options'; end if;
  if p_id is null then
    insert into markets (question, detail, options, closes_at, created_by)
    values (trim(p_question), nullif(trim(p_detail), ''), opts, p_closes, me.short) returning id into nid;
    return nid;
  end if;
  select * into mk from markets where id = p_id for update;
  if not found then raise exception 'no_market'; end if;
  if mk.options is distinct from opts and exists (select 1 from bets where market_id = p_id) then
    raise exception 'has_bets';
  end if;
  update markets set question = trim(p_question), detail = nullif(trim(p_detail), ''), options = opts, closes_at = p_closes
   where id = p_id;
  return p_id;
end $$;

-- Steve: open / close betting ---------------------------------------------------
create or replace function public.ftv_market_status(p_id uuid, p_open boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ftv_bookie_me();
  if not me.is_admin then raise exception 'not_allowed' using errcode = '42501'; end if;
  update markets set status = case when p_open then 'open' else 'closed' end,
                     closes_at = case when p_open and closes_at <= now() then null else closes_at end
   where id = p_id and status in ('open','closed');
end $$;

-- Steve: post the answer (p_winner = option index) or void it (p_winner = null). Can be redone to fix a mistake.
create or replace function public.ftv_market_settle(p_id uuid, p_winner int) returns void
language plpgsql security definer set search_path = public as $$
declare me players; mk markets; pot bigint; winpot bigint;
begin
  me := ftv_bookie_me();
  if not me.is_admin then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into mk from markets where id = p_id for update;
  if not found then raise exception 'no_market'; end if;
  if p_winner is not null and (p_winner < 0 or p_winner >= cardinality(mk.options)) then raise exception 'bad_option'; end if;

  select coalesce(sum(stake), 0), coalesce(sum(stake) filter (where option = p_winner), 0)
    into pot, winpot from bets where market_id = p_id;

  if p_winner is null or winpot = 0 then
    update bets set payout = stake where market_id = p_id;                       -- void / nobody right: refunds
  else
    update bets set payout = case when option = p_winner then (stake * pot) / winpot else 0 end
     where market_id = p_id;
  end if;
  update markets set status = case when p_winner is null then 'void' else 'settled' end,
                     winner = p_winner, settled_at = now()
   where id = p_id;
end $$;

-- Steve: undo a result (back to closed, payouts removed) -------------------------------
create or replace function public.ftv_market_unsettle(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ftv_bookie_me();
  if not me.is_admin then raise exception 'not_allowed' using errcode = '42501'; end if;
  update bets set payout = null where market_id = p_id;
  update markets set status = 'closed', winner = null, settled_at = null where id = p_id;
end $$;

-- Steve: delete a market (any bets on it are cancelled, money goes back) -------------
create or replace function public.ftv_market_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ftv_bookie_me();
  if not me.is_admin then raise exception 'not_allowed' using errcode = '42501'; end if;
  delete from markets where id = p_id;
end $$;

revoke all on function public.ftv_bet(uuid, int, bigint) from public;
revoke all on function public.ftv_market_save(uuid, text, text, text[], timestamptz) from public;
revoke all on function public.ftv_market_status(uuid, boolean) from public;
revoke all on function public.ftv_market_settle(uuid, int) from public;
revoke all on function public.ftv_market_unsettle(uuid) from public;
revoke all on function public.ftv_market_delete(uuid) from public;
grant execute on function public.ftv_bet(uuid, int, bigint) to authenticated;
grant execute on function public.ftv_market_save(uuid, text, text, text[], timestamptz) to authenticated;
grant execute on function public.ftv_market_status(uuid, boolean) to authenticated;
grant execute on function public.ftv_market_settle(uuid, int) to authenticated;
grant execute on function public.ftv_market_unsettle(uuid) to authenticated;
grant execute on function public.ftv_market_delete(uuid) to authenticated;

-- Starter markets (Steve can edit or delete any of them). Times are SAST.
insert into public.markets (seed, question, detail, options, closes_at, created_by) values
  ('m1', 'Who wins the cup?', 'Level after Saturday = split tour, both teams win.',
     array['Inland','Coastal','Split (tie)'], '2026-11-06 12:00+02', 'Steve'),
  ('m2', 'Who wins the Wooden Spoon?', 'Lowest individual Stableford points over both rounds.',
     array['Steve','Nic','Luke','Brandon','Guy','Mitch','Jay','Rich'], '2026-11-06 12:00+02', 'Steve'),
  ('m3', 'Top individual points over both rounds?', 'Most Stableford points across Friday and Saturday.',
     array['Steve','Nic','Luke','Brandon','Guy','Mitch','Jay','Rich'], '2026-11-06 12:00+02', 'Steve'),
  ('m4', 'Is Guy still standing at 22:00 on Friday?', '"9pm Bedtime" vs the tequila. Awake, upright and at the table counts.',
     array['Yes, tequilas out','No, tucked in'], '2026-11-06 20:00+02', 'Steve'),
  ('m5', 'Does Brandon stay for Saturday fines?', 'He''s "heading home after the rugby". Sure, Brands.',
     array['Stays and pays','Vanishes'], '2026-11-07 13:00+02', 'Steve'),
  ('m6', 'Springboks vs Italy: winning margin?', 'Sat 13:40 kick-off.',
     array['Boks by 1–15','Boks by 16–30','Boks by 31+','Italy win or draw'], '2026-11-07 13:40+02', 'Steve')
on conflict (seed) do nothing;

do $$ begin alter publication supabase_realtime add table public.markets; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.bets;    exception when duplicate_object then null; end $$;

-- Check: should show 6 open markets the first time.
select question, status, closes_at from public.markets order by created_at;
