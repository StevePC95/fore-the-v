-- Fore the V: Bookie extras — fixed odds vs the house, past tourists buy in, the Casino (roulette), market suggestions.
-- Run once in Supabase: SQL Editor > New query > paste all > Run. (Needs 009 first.) Safe to run again.
--  * FIXED ODDS AGAINST THE HOUSE (replaces the tote from 009): every answer has decimal odds (e.g. 2.5).
--    A bet locks in the odds at the moment it's placed; a win pays stake x odds from the house.
--    New markets start on fair-ish default odds (answers x 0.9); Steve can change odds any time (new bets only).
--    Scrapped market = stakes refunded.
--  * Past tourists can opt in ("buy in") and get their own R1,000,000 wallet.
--  * The Casino: European roulette (single 0). The spin happens here, not on the phone.
--  * Suggestions: anyone with a wallet can suggest a market. It costs R50,000 and they must pick their answer.
--      Steve declines = the R50,000 is gone. Pending = they can withdraw it for a refund.
--      Steve approves = the R50,000 becomes their opening bet on their pick at MAKER'S ODDS:
--      the odds on it are doubled (locked in when Steve approves).
--  * Wallet = R1,000,000 - bets staked + bets paid out - spins staked + spins paid out - suggestion fees still pending or declined.

-- Wallets -----------------------------------------------------------------------
create table if not exists public.bookie_joins (
  player_id text primary key references public.players (id),
  joined_at timestamptz not null default now()
);

create table if not exists public.casino_spins (
  id         uuid primary key default gen_random_uuid(),
  player_id  text not null references public.players (id),
  kind       text not null check (kind in ('num','red','black','odd','even','low','high','dozen')),
  pick       int,                       -- number 0-36 for 'num', 1-3 for 'dozen'
  stake      bigint not null check (stake > 0),
  result     int not null check (result between 0 and 36),
  payout     bigint not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists casino_spins_player_idx on public.casino_spins (player_id);
create index if not exists casino_spins_time_idx on public.casino_spins (created_at desc);

create table if not exists public.market_suggestions (
  id         uuid primary key default gen_random_uuid(),
  player_id  text not null references public.players (id),
  question   text not null check (length(trim(question)) between 3 and 160),
  detail     text check (length(detail) <= 400),
  options    text[] not null check (cardinality(options) between 2 and 10),
  pick       int not null check (pick >= 0),
  closes_at  timestamptz,
  fee        bigint not null,
  status     text not null default 'pending' check (status in ('pending','approved','declined','withdrawn')),
  market_id  uuid references public.markets (id) on delete set null,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

alter table public.bets add column if not exists boost int not null default 1;   -- 2 = maker's odds
alter table public.bets add column if not exists odds numeric(7,2);               -- locked in when the bet is placed
alter table public.markets add column if not exists odds numeric(7,2)[];          -- one per answer; null = default odds

-- Default odds: answers x 0.9 (a 10% house edge), never below 1.10. 2 answers = 1.80, 3 = 2.70, 8 = 7.20.
create or replace function public.ftv_default_odds(n int) returns numeric
language sql immutable as $$ select greatest(1.10, round(n * 0.9, 2)) $$;

create or replace function public.ftv_odds_of(mk markets, p_option int) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(mk.odds[p_option + 1], ftv_default_odds(cardinality(mk.options)));
$$;

alter table public.bookie_joins       enable row level security;
alter table public.casino_spins       enable row level security;
alter table public.market_suggestions enable row level security;
drop policy if exists "Members read joins" on public.bookie_joins;
drop policy if exists "Members read spins" on public.casino_spins;
drop policy if exists "Members read suggestions" on public.market_suggestions;
create policy "Members read joins" on public.bookie_joins for select to authenticated
  using (exists (select 1 from members where user_id = auth.uid()));
create policy "Members read spins" on public.casino_spins for select to authenticated
  using (exists (select 1 from members where user_id = auth.uid()));
create policy "Members read suggestions" on public.market_suggestions for select to authenticated
  using (exists (select 1 from members where user_id = auth.uid()));

-- Helpers ------------------------------------------------------------------------
create or replace function public.ftv_wallet_ok(p_player text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from players where id = p_player and team is not null)
      or exists (select 1 from bookie_joins where player_id = p_player);
$$;
grant execute on function public.ftv_wallet_ok(text) to authenticated;

create or replace function public.ftv_balance(p_player text) returns bigint
language sql stable security definer set search_path = public as $$
  select 1000000
    - coalesce((select sum(stake) - coalesce(sum(payout), 0) from bets where player_id = p_player), 0)
    - coalesce((select sum(stake) - sum(payout) from casino_spins where player_id = p_player), 0)
    - coalesce((select sum(fee) from market_suggestions where player_id = p_player and status in ('pending','declined')), 0);
$$;
grant execute on function public.ftv_balance(text) to authenticated;

-- Every money move for a player takes this lock first, so two phones can't double-spend.
create or replace function public.ftv_wallet_lock(p_player text) returns void
language sql security definer set search_path = public as $$
  select pg_advisory_xact_lock(hashtext('ftv_bet_' || p_player));
$$;
revoke all on function public.ftv_wallet_lock(text) from public, anon, authenticated;

-- Everyone with a wallet: balance + money still riding on unsettled bets.
create or replace function public.ftv_wallets()
returns table (player_id text, short text, team text, balance bigint, inplay bigint)
language sql stable security definer set search_path = public as $$
  select p.id, p.short, p.team, ftv_balance(p.id),
         coalesce((select sum(b.stake) from bets b where b.player_id = p.id and b.payout is null), 0)
  from players p
  where p.team is not null or exists (select 1 from bookie_joins j where j.player_id = p.id)
  order by p.sort;
$$;
grant execute on function public.ftv_wallets() to authenticated;

-- Past tourists: buy in ------------------------------------------------------------
create or replace function public.ftv_bookie_join() returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ftv_bookie_me();
  insert into bookie_joins (player_id) values (me.id) on conflict do nothing;
end $$;

-- Bets: now open to anyone with a wallet ------------------------------------------------
create or replace function public.ftv_bet(p_market uuid, p_option int, p_stake bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare me players; mk markets; bal bigint;
begin
  me := ftv_bookie_me();
  if not ftv_wallet_ok(me.id) then raise exception 'no_wallet'; end if;
  if p_stake is null or p_stake < 1 then raise exception 'bad_stake'; end if;
  perform ftv_wallet_lock(me.id);
  select * into mk from markets where id = p_market for update;
  if not found then raise exception 'no_market'; end if;
  if mk.status <> 'open' or (mk.closes_at is not null and mk.closes_at <= now()) then raise exception 'closed'; end if;
  if p_option < 0 or p_option >= cardinality(mk.options) then raise exception 'bad_option'; end if;
  bal := ftv_balance(me.id);
  if p_stake > bal then raise exception 'skint'; end if;
  insert into bets (market_id, player_id, option, stake, odds) values (p_market, me.id, p_option, p_stake, ftv_odds_of(mk, p_option));
  return bal - p_stake;
end $$;

-- Settle: winners get stake x locked odds (x2 for a maker's bet) from the house; scrapped = refunds.
create or replace function public.ftv_market_settle(p_id uuid, p_winner int) returns void
language plpgsql security definer set search_path = public as $$
declare me players; mk markets;
begin
  me := ftv_bookie_me();
  if not me.is_admin then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into mk from markets where id = p_id for update;
  if not found then raise exception 'no_market'; end if;
  if p_winner is not null and (p_winner < 0 or p_winner >= cardinality(mk.options)) then raise exception 'bad_option'; end if;
  if p_winner is null then
    update bets set payout = stake where market_id = p_id;
  else
    update bets set payout = case when option = p_winner
                                  then floor(stake * coalesce(odds, ftv_odds_of(mk, option)) * boost)::bigint
                                  else 0 end
     where market_id = p_id;
  end if;
  update markets set status = case when p_winner is null then 'void' else 'settled' end,
                     winner = p_winner, settled_at = now()
   where id = p_id;
end $$;

-- Steve: create or edit a market, now with odds per answer (null = default odds).
create or replace function public.ftv_market_save(p_id uuid, p_question text, p_detail text, p_options text[], p_closes timestamptz, p_odds numeric[])
returns uuid language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  if p_odds is not null and exists (select 1 from unnest(p_odds) o where o is null or o < 1.01 or o > 1000) then
    raise exception 'bad_odds';
  end if;
  nid := ftv_market_save(p_id, p_question, p_detail, p_options, p_closes);
  if p_odds is not null and cardinality(p_odds) <> (select cardinality(options) from markets where id = nid) then
    raise exception 'bad_odds';
  end if;
  update markets set odds = p_odds where id = nid;
  return nid;
end $$;
revoke all on function public.ftv_market_save(uuid, text, text, text[], timestamptz, numeric[]) from public;
grant execute on function public.ftv_market_save(uuid, text, text, text[], timestamptz, numeric[]) to authenticated;

-- The Casino: European roulette ----------------------------------------------------
create or replace function public.ftv_spin(p_kind text, p_pick int, p_stake bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me players; bal bigint; r int; win boolean; mult int; pay bigint;
  reds int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
begin
  me := ftv_bookie_me();
  if not ftv_wallet_ok(me.id) then raise exception 'no_wallet'; end if;
  if p_stake is null or p_stake < 1 then raise exception 'bad_stake'; end if;
  if p_kind not in ('num','red','black','odd','even','low','high','dozen') then raise exception 'bad_bet'; end if;
  if p_kind = 'num' and (p_pick is null or p_pick < 0 or p_pick > 36) then raise exception 'bad_bet'; end if;
  if p_kind = 'dozen' and (p_pick is null or p_pick < 1 or p_pick > 3) then raise exception 'bad_bet'; end if;
  perform ftv_wallet_lock(me.id);
  bal := ftv_balance(me.id);
  if p_stake > bal then raise exception 'skint'; end if;

  r := floor(random() * 37)::int;
  win := case p_kind
    when 'num'   then r = p_pick
    when 'red'   then r = any(reds)
    when 'black' then r > 0 and not (r = any(reds))
    when 'odd'   then r > 0 and r % 2 = 1
    when 'even'  then r > 0 and r % 2 = 0
    when 'low'   then r between 1 and 18
    when 'high'  then r between 19 and 36
    when 'dozen' then r between (p_pick - 1) * 12 + 1 and p_pick * 12
  end;
  mult := case p_kind when 'num' then 36 when 'dozen' then 3 else 2 end;   -- money back incl. stake
  pay := case when win then p_stake * mult else 0 end;
  insert into casino_spins (player_id, kind, pick, stake, result, payout)
  values (me.id, p_kind, case when p_kind in ('num','dozen') then p_pick end, p_stake, r, pay);
  return jsonb_build_object('result', r, 'payout', pay, 'balance', bal - p_stake + pay);
end $$;

-- Suggestions ---------------------------------------------------------------------
create or replace function public.ftv_suggest(p_question text, p_detail text, p_options text[], p_closes timestamptz, p_pick int)
returns uuid language plpgsql security definer set search_path = public as $$
declare me players; opts text[]; fee bigint := 50000; nid uuid;
begin
  me := ftv_bookie_me();
  if not ftv_wallet_ok(me.id) then raise exception 'no_wallet'; end if;
  select array_agg(trim(o)) into opts from unnest(p_options) o where length(trim(o)) > 0;
  if coalesce(cardinality(opts), 0) < 2 then raise exception 'need_two_options'; end if;
  if p_pick is null or p_pick < 0 or p_pick >= cardinality(opts) then raise exception 'need_pick'; end if;
  perform ftv_wallet_lock(me.id);
  if ftv_balance(me.id) < fee then raise exception 'skint'; end if;
  insert into market_suggestions (player_id, question, detail, options, pick, closes_at, fee)
  values (me.id, trim(p_question), nullif(trim(p_detail), ''), opts, p_pick, p_closes, fee) returning id into nid;
  return nid;
end $$;

create or replace function public.ftv_suggest_withdraw(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ftv_bookie_me();
  update market_suggestions set status = 'withdrawn', decided_at = now()
   where id = p_id and player_id = me.id and status = 'pending';
  if not found then raise exception 'not_pending'; end if;
end $$;

create or replace function public.ftv_suggest_decide(p_id uuid, p_approve boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare me players; s market_suggestions; who players; nid uuid;
begin
  me := ftv_bookie_me();
  if not me.is_admin then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into s from market_suggestions where id = p_id for update;
  if not found or s.status <> 'pending' then raise exception 'not_pending'; end if;
  if not p_approve then
    update market_suggestions set status = 'declined', decided_at = now() where id = p_id;
    return null;
  end if;
  select * into who from players where id = s.player_id;
  insert into markets (question, detail, options, closes_at, created_by)
  values (s.question, s.detail, s.options, case when s.closes_at > now() then s.closes_at end, who.short)
  returning id into nid;
  insert into bets (market_id, player_id, option, stake, boost, odds)
  values (nid, s.player_id, s.pick, s.fee, 2, ftv_default_odds(cardinality(s.options)));
  update market_suggestions set status = 'approved', market_id = nid, decided_at = now() where id = p_id;
  return nid;
end $$;

revoke all on function public.ftv_bookie_join() from public;
revoke all on function public.ftv_spin(text, int, bigint) from public;
revoke all on function public.ftv_suggest(text, text, text[], timestamptz, int) from public;
revoke all on function public.ftv_suggest_withdraw(uuid) from public;
revoke all on function public.ftv_suggest_decide(uuid, boolean) from public;
grant execute on function public.ftv_bookie_join() to authenticated;
grant execute on function public.ftv_spin(text, int, bigint) to authenticated;
grant execute on function public.ftv_suggest(text, text, text[], timestamptz, int) to authenticated;
grant execute on function public.ftv_suggest_withdraw(uuid) to authenticated;
grant execute on function public.ftv_suggest_decide(uuid, boolean) to authenticated;

do $$ begin alter publication supabase_realtime add table public.bookie_joins;       exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.casino_spins;       exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.market_suggestions; exception when duplicate_object then null; end $$;

-- Check: everyone with a wallet (the 8 to start with).
select * from public.ftv_wallets();
