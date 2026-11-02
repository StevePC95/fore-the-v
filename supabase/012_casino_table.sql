-- Fore the V: the Casino table. Several chips per spin (cover two dozens, a number and red, whatever).
-- Run once in Supabase: SQL Editor > New query > paste all > Run. (Needs 010 first.) Safe to run again.
--  * ftv_spin_table(p_bets) takes a list of chips: [{"kind":"dozen","pick":1,"stake":50000}, {"kind":"num","pick":17,"stake":10000}]
--  * One spin of the wheel settles every chip. Each chip is saved as its own row, grouped by spin_id.
--  * Same pays as before: red/black, odd/even, 1-18/19-36 = 2x back; dozens = 3x; a single number = 36x.

alter table public.casino_spins add column if not exists spin_id uuid;
create index if not exists casino_spins_spin_idx on public.casino_spins (spin_id);

create or replace function public.ftv_spin_table(p_bets jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me players; bal bigint; r int; total bigint := 0; paid bigint := 0; sid uuid := gen_random_uuid();
  b jsonb; k text; pk int; stk bigint; win boolean; mult int; pay bigint;
  reds int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
begin
  me := ftv_bookie_me();
  if not ftv_wallet_ok(me.id) then raise exception 'no_wallet'; end if;
  if p_bets is null or jsonb_typeof(p_bets) <> 'array' or jsonb_array_length(p_bets) = 0 then raise exception 'bad_bet'; end if;
  if jsonb_array_length(p_bets) > 60 then raise exception 'bad_bet'; end if;
  -- check every chip before spinning
  for b in select * from jsonb_array_elements(p_bets) loop
    k := b->>'kind'; pk := (b->>'pick')::int; stk := (b->>'stake')::bigint;
    if k not in ('num','red','black','odd','even','low','high','dozen') then raise exception 'bad_bet'; end if;
    if k = 'num' and (pk is null or pk < 0 or pk > 36) then raise exception 'bad_bet'; end if;
    if k = 'dozen' and (pk is null or pk < 1 or pk > 3) then raise exception 'bad_bet'; end if;
    if stk is null or stk < 1 then raise exception 'bad_stake'; end if;
    total := total + stk;
  end loop;
  perform ftv_wallet_lock(me.id);
  bal := ftv_balance(me.id);
  if total > bal then raise exception 'skint'; end if;

  r := floor(random() * 37)::int;
  for b in select * from jsonb_array_elements(p_bets) loop
    k := b->>'kind'; pk := (b->>'pick')::int; stk := (b->>'stake')::bigint;
    win := case k
      when 'num'   then r = pk
      when 'red'   then r = any(reds)
      when 'black' then r > 0 and not (r = any(reds))
      when 'odd'   then r > 0 and r % 2 = 1
      when 'even'  then r > 0 and r % 2 = 0
      when 'low'   then r between 1 and 18
      when 'high'  then r between 19 and 36
      when 'dozen' then r between (pk - 1) * 12 + 1 and pk * 12
    end;
    mult := case k when 'num' then 36 when 'dozen' then 3 else 2 end;
    pay := case when win then stk * mult else 0 end;
    paid := paid + pay;
    insert into casino_spins (player_id, kind, pick, stake, result, payout, spin_id)
    values (me.id, k, case when k in ('num','dozen') then pk end, stk, r, pay, sid);
  end loop;
  return jsonb_build_object('result', r, 'staked', total, 'payout', paid, 'balance', bal - total + paid, 'spin_id', sid);
end $$;
revoke all on function public.ftv_spin_table(jsonb) from public;
grant execute on function public.ftv_spin_table(jsonb) to authenticated;

notify pgrst, 'reload schema';
