-- Fore the V: profiles, personal PINs, change requests, Steve's desk.
-- Run once in Supabase: SQL Editor > New query > paste all > Run. (Needs 013 first.) Safe to run again.
--  * Everyone claims their own profile with a 4-digit PIN (first come). PINs are stored hashed: nobody can read them,
--    Steve can only reset one (which also signs that name out everywhere). 5 wrong tries = locked for 15 minutes.
--  * Sign-in = group code + name + PIN. The shared Tour V code is retired: what you can do comes from your profile
--    (is_admin, is_captain, is_exec, is_scorer).
--  * Profile: first name, surname and photo are yours to change. Tour name, nickname, hometown and bio go to Steve
--    as a change request. Handicaps stay with the organisers.

-- 1. Profile fields + roles -------------------------------------------------------
alter table public.players add column if not exists first_name text;
alter table public.players add column if not exists surname    text;
alter table public.players add column if not exists nickname   text;
alter table public.players add column if not exists bio        text;
alter table public.players add column if not exists hometown   text;
alter table public.players add column if not exists handicap   numeric(4,1);
alter table public.players add column if not exists photo_path text;
alter table public.players add column if not exists is_exec    boolean not null default false;
alter table public.players add column if not exists is_scorer  boolean not null default false;

update public.players set first_name = coalesce(first_name, split_part(name, ' ', 1)),
                          surname    = coalesce(surname, nullif(substr(name, length(split_part(name, ' ', 1)) + 2), ''));
update public.players set is_exec = true   where id in ('steve','nic','brandon','guy');
update public.players set is_scorer = true where team is not null;

update public.players p set nickname = v.nick, hometown = v.home, handicap = v.hcp, bio = v.bio
from (values
  ('steve','Wooden Spoon','Sandton, GP',26,'To keep ball costs down, you won''t see his driver. Runs on brandy and may smell suspicious on the back nine.'),
  ('nic','0 Tour Wins','Sandton, GP',13,'Plans the whole bloody tour, still waiting to win one. Hopefully no spelling mistakes on the tour shirts this year.'),
  ('luke','Young Skywalker','Centurion, GP',20,'First tour, and worried the "ballies" won''t be able to keep up. Says he loves a beer, but may fall asleep in a bathroom stall afterwards.'),
  ('brandon','Whistle Blower','Pretoria, GP',10,'Mr. Discovery during the week, Bryce Lawrence on the weekend. Has conveniently made plans to disappear before fines.'),
  ('guy','9pm Bedtime','Durbanville, WC',14,'Big fan of an afternoon nap. Get him past 10pm and watch the tequilas start coming out.'),
  ('mitch','Hansa Draught Please','Hillcrest, KZN',30,'Golf frustrates him. The bar does not. Don''t walk slowly in front of his car…'),
  ('jay','Pro Golfer','Umdloti, KZN',26,'Would marry Rassie Erasmus if he could.'),
  ('rich','Massive Calves','Richmond, KZN',14,'Guaranteed to wear shorts to show off his legs. Mr Consistent on the golf course and at the bar, but swears he never has time for either.')
) as v(id, nick, home, hcp, bio)
where p.id = v.id and p.nickname is null;

create or replace function public.ftv_is_exec() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members m join players p on p.id = m.player_id where m.user_id = auth.uid() and p.is_exec);
$$;

-- 2. PINs (separate table: never readable from the app) ----------------------------------
create table if not exists public.player_pins (
  player_id    text primary key references public.players (id),
  pin_hash     text not null,
  set_at       timestamptz not null default now(),
  fails        int not null default 0,
  locked_until timestamptz
);
alter table public.player_pins enable row level security;

-- Checks a PIN. Returns 'ok', 'bad' (with tries counted) or 'locked'. Never raises, so a failed try is remembered.
create or replace function public.ftv_pin_check(p_player text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare r player_pins;
begin
  select * into r from player_pins where player_id = p_player for update;
  if not found then return 'unclaimed'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if r.pin_hash = crypt(coalesce(p_pin, ''), r.pin_hash) then
    update player_pins set fails = 0, locked_until = null where player_id = p_player;
    return 'ok';
  end if;
  if r.fails + 1 >= 5 then
    update player_pins set fails = 0, locked_until = now() + interval '15 minutes' where player_id = p_player;
    return 'locked';
  end if;
  update player_pins set fails = r.fails + 1 where player_id = p_player;
  return 'bad';
end $$;
revoke all on function public.ftv_pin_check(text, text) from public, anon, authenticated;

create or replace function public.ftv_set_pin(p_player text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'bad_pin_format'; end if;
  insert into player_pins (player_id, pin_hash) values (p_player, crypt(p_pin, gen_salt('bf')))
  on conflict (player_id) do update set pin_hash = excluded.pin_hash, set_at = now(), fails = 0, locked_until = null;
end $$;
revoke all on function public.ftv_set_pin(text, text) from public, anon, authenticated;

-- 3. Who's signed in -----------------------------------------------------------------
create or replace function public.ftv_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('player_id', m.player_id, 'name', m.display_name, 'short', coalesce(p.short, m.display_name),
                            'team', p.team, 'tour_access', m.tour_access, 'is_admin', coalesce(p.is_admin, false),
                            'is_captain', coalesce(p.is_captain, false), 'is_exec', coalesce(p.is_exec, false),
                            'is_scorer', coalesce(p.is_scorer, false),
                            'is_test', coalesce(p.is_test, false), 'test_of', m.test_of,
                            'claimed', exists (select 1 from player_pins x where x.player_id = m.player_id),
                            'first_name', p.first_name, 'surname', p.surname, 'nickname', p.nickname, 'photo_path', p.photo_path)
  from members m left join players p on p.id = m.player_id
  where m.user_id = auth.uid();
$$;

-- Sign-in step: is this name claimed yet? (needs the group code)
create or replace function public.ftv_player_status(p_code text, p_player text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not ftv_check_group(p_code) then null else
    jsonb_build_object('claimed', exists (select 1 from player_pins where player_id = p_player),
                       'admin', coalesce((select is_admin from players where id = p_player), false),
                       'locked', coalesce((select locked_until > now() from player_pins where player_id = p_player), false)) end;
$$;
grant execute on function public.ftv_player_status(text, text) to anon, authenticated;

-- Sign in with a PIN, or claim an unclaimed name by choosing one.
create or replace function public.ftv_sign_in(p_code text, p_player text, p_pin text, p_admin_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pl players; chk text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not ftv_check_group(p_code) then raise exception 'bad_code' using errcode = '28P01'; end if;
  select * into pl from players where id = p_player;
  if not found or pl.is_test then raise exception 'bad_player'; end if;
  if exists (select 1 from player_pins where player_id = pl.id) then
    chk := ftv_pin_check(pl.id, p_pin);
    if chk <> 'ok' then return jsonb_build_object('error', case when chk = 'locked' then 'locked' else 'bad_pin' end); end if;
  else
    if pl.is_admin and not ftv_code_ok(pl.id, p_admin_code) then raise exception 'bad_tour_code' using errcode = '28P01'; end if;
    perform ftv_set_pin(pl.id, p_pin);                                  -- first come: this phone claims the name
  end if;
  insert into members (user_id, player_id, display_name, tour_access)
  values (auth.uid(), pl.id, pl.name, pl.is_scorer)
  on conflict (user_id) do update set player_id = excluded.player_id, display_name = excluded.display_name,
    tour_access = excluded.tour_access;
  return ftv_me();
end $$;
grant execute on function public.ftv_sign_in(text, text, text, text) to authenticated;

-- Old sign-in: named players must now use a PIN. Guests ("someone else") still work.
create or replace function public.ftv_join(p_code text, p_player text, p_name text default null, p_tour_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not ftv_check_group(p_code) then raise exception 'bad_code' using errcode = '28P01'; end if;
  if p_player is not null then raise exception 'needs_pin'; end if;
  nm := nullif(trim(coalesce(p_name, '')), '');
  if nm is null then raise exception 'bad_name'; end if;
  insert into members (user_id, player_id, display_name, tour_access)
  values (auth.uid(), null, nm, false)
  on conflict (user_id) do update set player_id = null, display_name = excluded.display_name, tour_access = false;
  return ftv_me();
end $$;

-- Already signed in from before PINs: claim your name from the Profile tab.
create or replace function public.ftv_claim(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players;
begin
  select p.* into pl from members m join players p on p.id = m.player_id where m.user_id = auth.uid();
  if not found or pl.is_test then raise exception 'not_allowed' using errcode = '42501'; end if;
  if exists (select 1 from player_pins where player_id = pl.id) then raise exception 'already_claimed'; end if;
  perform ftv_set_pin(pl.id, p_pin);
  update members set tour_access = pl.is_scorer where user_id = auth.uid();
  return ftv_me();
end $$;
grant execute on function public.ftv_claim(text) to authenticated;

create or replace function public.ftv_change_pin(p_old text, p_new text) returns text
language plpgsql security definer set search_path = public as $$
declare pid text; chk text;
begin
  select player_id into pid from members where user_id = auth.uid();
  if pid is null then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_new is null or p_new !~ '^[0-9]{4}$' then raise exception 'bad_pin_format'; end if;
  chk := ftv_pin_check(pid, p_old);
  if chk <> 'ok' then return chk; end if;
  perform ftv_set_pin(pid, p_new);
  return 'ok';
end $$;
grant execute on function public.ftv_change_pin(text, text) to authenticated;

-- Steve: who has claimed, and reset a PIN (also signs that name out on every phone but Steve's).
create or replace function public.ftv_claims() returns table (player_id text, claimed boolean, set_at timestamptz, locked boolean)
language sql stable security definer set search_path = public as $$
  select p.id, x.player_id is not null, case when ftv_is_admin() then x.set_at end, coalesce(x.locked_until > now(), false)
  from players p left join player_pins x on x.player_id = p.id
  where not p.is_test order by p.sort;
$$;
grant execute on function public.ftv_claims() to authenticated;

create or replace function public.ftv_reset_pin(p_player text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ftv_is_admin() then raise exception 'not_allowed' using errcode = '42501'; end if;
  delete from player_pins where player_id = p_player;
  delete from members where player_id = p_player and user_id <> auth.uid() and test_of is null;
end $$;
grant execute on function public.ftv_reset_pin(text) to authenticated;

-- 4. Your own edits: names and photo -----------------------------------------------------
create or replace function public.ftv_update_me(p_first text, p_surname text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pid text; f text := nullif(trim(coalesce(p_first,'')),''); s text := nullif(trim(coalesce(p_surname,'')),'');
begin
  select player_id into pid from members where user_id = auth.uid();
  if pid is null or exists (select 1 from players where id = pid and is_test) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if f is null or length(f) > 40 or length(coalesce(s,'')) > 60 then raise exception 'bad_name'; end if;
  update players set first_name = f, surname = s, name = trim(f || ' ' || coalesce(s, '')) where id = pid;
  update members set display_name = trim(f || ' ' || coalesce(s, '')) where player_id = pid;
  return ftv_me();
end $$;
grant execute on function public.ftv_update_me(text, text) to authenticated;

create or replace function public.ftv_set_photo(p_path text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pid text;
begin
  select player_id into pid from members where user_id = auth.uid();
  if pid is null then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_path is not null and split_part(p_path, '/', 1) <> pid then raise exception 'not_allowed' using errcode = '42501'; end if;
  update players set photo_path = p_path where id = pid;
  return ftv_me();
end $$;
grant execute on function public.ftv_set_photo(text) to authenticated;

insert into storage.buckets (id, name, public) values ('avatars', 'avatars', false) on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='FTV members read avatars') then
    create policy "FTV members read avatars" on storage.objects for select to authenticated
      using (bucket_id = 'avatars' and public.ftv_is_member());
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='FTV upload own avatar') then
    create policy "FTV upload own avatar" on storage.objects for insert to authenticated
      with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.ftv_my_player());
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='FTV replace own avatar') then
    create policy "FTV replace own avatar" on storage.objects for update to authenticated
      using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.ftv_my_player());
  end if;
end $$;

-- 5. Change requests (tour name, nickname, hometown, bio) -> Steve -------------------------
create table if not exists public.profile_requests (
  id         uuid primary key default gen_random_uuid(),
  player_id  text not null references public.players (id),
  field      text not null check (field in ('short','nickname','hometown','bio')),
  old_value  text,
  new_value  text not null check (length(new_value) between 1 and 400),
  note       text check (length(note) <= 300),
  status     text not null default 'pending' check (status in ('pending','approved','declined','withdrawn')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
alter table public.profile_requests enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='profile_requests' and policyname='Own or admin read requests') then
    create policy "Own or admin read requests" on public.profile_requests for select to authenticated
      using (player_id = public.ftv_my_player() or public.ftv_is_admin());
  end if;
end $$;

create or replace function public.ftv_request_change(p_field text, p_value text, p_note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid text; oldv text; nid uuid; v text := nullif(trim(coalesce(p_value,'')),'');
begin
  select player_id into pid from members where user_id = auth.uid();
  if pid is null or exists (select 1 from players where id = pid and is_test) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_field not in ('short','nickname','hometown','bio') or v is null then raise exception 'bad_request'; end if;
  if p_field = 'short' and length(v) > 20 then raise exception 'bad_request'; end if;
  if p_field in ('nickname','hometown') and length(v) > 40 then raise exception 'bad_request'; end if;
  execute format('select %I::text from players where id = $1', p_field) into oldv using pid;
  update profile_requests set status = 'withdrawn', decided_at = now() where player_id = pid and field = p_field and status = 'pending';
  insert into profile_requests (player_id, field, old_value, new_value, note)
  values (pid, p_field, oldv, v, nullif(trim(coalesce(p_note,'')),'')) returning id into nid;
  return nid;
end $$;
grant execute on function public.ftv_request_change(text, text, text) to authenticated;

create or replace function public.ftv_request_withdraw(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update profile_requests set status = 'withdrawn', decided_at = now()
   where id = p_id and status = 'pending' and player_id = ftv_my_player();
  if not found then raise exception 'not_pending'; end if;
end $$;
grant execute on function public.ftv_request_withdraw(uuid) to authenticated;

create or replace function public.ftv_request_decide(p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r profile_requests;
begin
  if not ftv_is_admin() then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into r from profile_requests where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception 'not_pending'; end if;
  if p_approve then
    execute format('update players set %I = $1 where id = $2', r.field) using r.new_value, r.player_id;
  end if;
  update profile_requests set status = case when p_approve then 'approved' else 'declined' end, decided_at = now() where id = p_id;
end $$;
grant execute on function public.ftv_request_decide(uuid, boolean) to authenticated;

-- 6. Profile stats --------------------------------------------------------------------
create or replace function public.ftv_profile_stats(p_player text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not ftv_is_member() then null else jsonb_build_object(
    'wallet', case when ftv_wallet_ok(p_player) and (not (select is_test from players where id = p_player) or p_player = ftv_my_player())
                   then ftv_balance(p_player) end,
    'bets', (select count(*) from bets where player_id = p_player),
    'spins', (select count(distinct coalesce(spin_id, id)) from casino_spins where player_id = p_player),
    'casino_net', (select coalesce(sum(payout - stake), 0) from casino_spins where player_id = p_player),
    'dops', (select count(*) from dop_videos where drinker = p_player),
    'pitches', (select count(*) from market_suggestions where player_id = p_player and status = 'approved')
  ) end;
$$;
grant execute on function public.ftv_profile_stats(text) to authenticated;

do $$ begin alter publication supabase_realtime add table public.profile_requests; exception when duplicate_object then null; end $$;
notify pgrst, 'reload schema';

-- Check
select id, first_name, surname, nickname, is_exec, is_scorer from public.players where team is not null order by sort;
