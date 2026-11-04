-- Fore the V: The Feed (chat + app messages) and "everyone changes everyone else's profile pic".
-- Safe to run more than once. Applied directly to Supabase on 4 Nov (no drops).
--
-- 1. Profile pics: you can no longer change your own. Anyone on the list can change anyone else's.
-- 2. The Feed: a live chat for members, plus messages the app posts itself
--    (bets, markets, results, roulette, pics, fullies, comments, photos, buy-ins, approved changes, locked scores).
--    App messages are written by database triggers, so nobody can fake them from a phone.
--    Body tokens: {who} = the person who did it (actor_name), {link} = link_label, linking to link_href (+ link_ref = element id).
--    Anything done on the test profile is hidden from everyone except the test profile and Steve.

-- 1. Profile pics ------------------------------------------------------------------------
create or replace function public.ftv_set_photo(p_path text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'own_photo' using errcode = '42501';   -- your pic is in the boys' hands now
end $$;

create or replace function public.ftv_set_photo_for(p_player text, p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare me text; tgt players;
begin
  me := ftv_my_player();
  if me is null or exists (select 1 from players where id = me and is_test) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_player = me then raise exception 'own_photo' using errcode = '42501'; end if;
  select * into tgt from players where id = p_player;
  if not found or tgt.is_test then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> p_player then raise exception 'not_allowed' using errcode = '42501'; end if;
  update players set photo_path = p_path where id = p_player;
end $$;
revoke all on function public.ftv_set_photo_for(text, text) from public, anon;
grant execute on function public.ftv_set_photo_for(text, text) to authenticated;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='FTV upload others avatars') then
    create policy "FTV upload others avatars" on storage.objects for insert to authenticated
      with check (bucket_id = 'avatars' and public.ftv_my_player() is not null
                  and (storage.foldername(name))[1] <> public.ftv_my_player());
  end if;
end $$;

-- 2. The Feed ----------------------------------------------------------------------------
create table if not exists public.feed (
  id          bigserial primary key,
  kind        text not null check (kind in ('chat','app')),
  icon        text,
  actor       text,
  actor_name  text,
  body        text not null check (length(body) between 1 and 700),
  link_label  text,
  link_href   text,
  link_ref    text,
  hidden      boolean not null default false,
  posted_by   uuid,
  created_at  timestamptz not null default now()
);
create index if not exists feed_time_idx on public.feed (created_at desc);
alter table public.feed enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='feed' and policyname='Members read the feed') then
    create policy "Members read the feed" on public.feed for select to authenticated
      using (public.ftv_is_member() and (not hidden or posted_by = auth.uid() or public.ftv_is_admin()));
  end if;
  if not exists (select 1 from pg_policies where tablename='feed' and policyname='Delete your own chat') then
    create policy "Delete your own chat" on public.feed for delete to authenticated
      using ((kind = 'chat' and posted_by = auth.uid()) or public.ftv_is_admin());
  end if;
end $$;
grant select, delete on public.feed to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.feed;
exception when duplicate_object then null; end $$;

-- R1,250,000 -> R1.25m, R50,000 -> R50k
create or replace function public.ftv_rk(n bigint) returns text
language sql immutable as $$
  select case
    when abs(n) >= 1000000 then 'R' || trim_scale(round(abs(n) / 1000000.0, 2)) || 'm'
    when abs(n) >= 1000    then 'R' || trim_scale(round(abs(n) / 1000.0, 1)) || 'k'
    else 'R' || abs(n) end;
$$;

-- Display name for a player id (or the text itself, for typed names)
create or replace function public.ftv_pname(p text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select coalesce(short, name) from players where id = p), p);
$$;

-- App message. Hidden if the actor (or anyone involved) is the test profile.
create or replace function public.ftv_feed_post(p_actor text, p_icon text, p_body text,
  p_label text default null, p_href text default null, p_ref text default null, p_hide boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare nm text; tst boolean;
begin
  select coalesce(short, name), is_test into nm, tst from players where id = p_actor;
  insert into feed (kind, icon, actor, actor_name, body, link_label, link_href, link_ref, hidden, posted_by)
  values ('app', p_icon, p_actor, coalesce(nm, 'Someone'), left(p_body, 700), p_label, p_href, p_ref,
          coalesce(tst, false) or coalesce(p_hide, false), auth.uid());
end $$;
revoke all on function public.ftv_feed_post(text, text, text, text, text, text, boolean) from public, anon, authenticated;

-- Chat (members only)
create or replace function public.ftv_chat(p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare b text := trim(coalesce(p_body, '')); pid text; nm text; tst boolean;
begin
  if not ftv_is_member() then raise exception 'not_allowed' using errcode = '42501'; end if;
  if length(b) < 1 or length(b) > 500 then raise exception 'bad_body'; end if;
  select m.player_id, coalesce(p.short, m.display_name), coalesce(p.is_test, false)
    into pid, nm, tst from members m left join players p on p.id = m.player_id where m.user_id = auth.uid();
  insert into feed (kind, actor, actor_name, body, hidden, posted_by)
  values ('chat', pid, coalesce(nm, 'Someone'), b, coalesce(tst, false), auth.uid());
end $$;
revoke all on function public.ftv_chat(text) from public, anon;
grant execute on function public.ftv_chat(text) to authenticated;

-- 3. App messages ------------------------------------------------------------------------
-- Bets
create or replace function public.ftv_feed_bet() returns trigger
language plpgsql security definer set search_path = public as $$
declare mk markets; od numeric;
begin
  select * into mk from markets where id = new.market_id;
  if not found then return new; end if;
  od := coalesce(new.odds, ftv_odds_of(mk, new.option)) * coalesce(new.boost, 1);
  if coalesce(new.boost, 1) > 1 then
    perform ftv_feed_post(new.player_id, '🤝', '{who}''s pitch got the nod: ' || ftv_rk(new.stake) || ' on ' ||
      mk.options[new.option + 1] || ' @ ' || to_char(od, 'FM9990.00') || ' (maker''s odds) in {link}', mk.question, '#bookie', 'mk-' || mk.id);
  else
    perform ftv_feed_post(new.player_id, '🎲', '{who} put ' || ftv_rk(new.stake) || ' on ' ||
      mk.options[new.option + 1] || ' @ ' || to_char(od, 'FM9990.00') || ' in {link}', mk.question, '#bookie', 'mk-' || mk.id);
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_bet') then
    create trigger feed_bet after insert on public.bets for each row execute function public.ftv_feed_bet();
  end if;
end $$;

-- Markets: new, results, scrapped
create or replace function public.ftv_feed_market() returns trigger
language plpgsql security definer set search_path = public as $$
declare me text := ftv_my_player();
begin
  if tg_op = 'INSERT' then
    perform ftv_feed_post(me, '📈', '{who} opened a new market: {link}', new.question, '#bookie', 'mk-' || new.id);
  elsif new.status is distinct from old.status then
    if new.status = 'settled' and new.winner is not null then
      perform ftv_feed_post(me, '🏁', 'Result in: {link} → ' || new.options[new.winner + 1] || '. Winners paid.', new.question, '#bookie', 'mk-' || new.id);
    elsif new.status = 'void' then
      perform ftv_feed_post(me, '🗑️', '{link} was scrapped. Everyone refunded.', new.question, '#bookie', 'mk-' || new.id);
    end if;
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_market') then
    create trigger feed_market after insert or update of status on public.markets for each row execute function public.ftv_feed_market();
  end if;
end $$;

-- Roulette: one message per spin, only for a big win (R100k+) or a big loss (R250k+)
create or replace function public.ftv_feed_casino() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select player_id, (sum(payout) - sum(stake))::bigint as net from new_rows group by player_id, coalesce(spin_id, id) loop
    if r.net >= 100000 then
      perform ftv_feed_post(r.player_id, '🎰', '{who} won ' || ftv_rk(r.net) || ' at {link}', 'the roulette table', '#bookie', 'rl');
    elsif r.net <= -250000 then
      perform ftv_feed_post(r.player_id, '💸', '{who} just donated ' || ftv_rk(-r.net) || ' to the house at {link}', 'the roulette table', '#bookie', 'rl');
    end if;
  end loop;
  return null;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_casino') then
    create trigger feed_casino after insert on public.casino_spins referencing new table as new_rows
      for each statement execute function public.ftv_feed_casino();
  end if;
end $$;

-- Buy-ins
create or replace function public.ftv_feed_join() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform ftv_feed_post(new.player_id, '💰', '{who} bought into {link} with a fresh R1m', 'the Bookie', '#bookie', null);
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_join') then
    create trigger feed_join after insert on public.bookie_joins for each row execute function public.ftv_feed_join();
  end if;
end $$;

-- Profile pics
create or replace function public.ftv_feed_pic() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.photo_path is not null and new.photo_path is distinct from old.photo_path then
    perform ftv_feed_post(ftv_my_player(), '📸', '{who} changed {link}', coalesce(new.short, new.name) || '’s profile pic',
      '#players', 'pl-' || new.id, new.is_test);
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_pic') then
    create trigger feed_pic after update of photo_path on public.players for each row execute function public.ftv_feed_pic();
  end if;
end $$;

-- Approved profile changes
create or replace function public.ftv_feed_request() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text := ftv_pname(new.player_id); f text;
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    f := case new.field when 'short' then 'tour name' else new.field end;
    perform ftv_feed_post(ftv_my_player(), '✅', '{who} approved {link}: “' || left(new.new_value, 120) || '”',
      who || '’s new ' || f, '#players', 'pl-' || new.player_id);
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_request') then
    create trigger feed_request after update of status on public.profile_requests for each row execute function public.ftv_feed_request();
  end if;
end $$;

-- Fullies
create or replace function public.ftv_feed_fully() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform ftv_feed_post(ftv_my_player(), '🍺', '{who} filmed {link}', ftv_pname(new.drinker) || '’s fully', '#dops', 'dv-' || new.id);
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_fully') then
    create trigger feed_fully after insert on public.dop_videos for each row execute function public.ftv_feed_fully();
  end if;
end $$;

-- Comments on fullies
create or replace function public.ftv_feed_fully_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare dr text;
begin
  select drinker into dr from dop_videos where id = new.video_id;
  perform ftv_feed_post(ftv_my_player(), '💬', '{who} on {link}: “' || left(new.body, 100) || case when length(new.body) > 100 then '…' else '' end || '”',
    ftv_pname(dr) || '’s fully', '#dops', 'dv-' || new.video_id);
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_fully_comment') then
    create trigger feed_fully_comment after insert on public.dop_comments for each row execute function public.ftv_feed_fully_comment();
  end if;
end $$;

-- Photos
create or replace function public.ftv_feed_photo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform ftv_feed_post(ftv_my_player(), '🖼️', '{who} posted {link}' ||
    case new.album when 't1' then ' (Tour I)' when 't2' then ' (Tour II)' when 't3' then ' (Tour III)' when 't4' then ' (Tour IV)' when 't5' then ' (Tour V)' else '' end,
    'a photo', '#photos', null);
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_photo') then
    create trigger feed_photo after insert on public.photos for each row execute function public.ftv_feed_photo();
  end if;
end $$;

-- Scores locked
create or replace function public.ftv_feed_lock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not new.locked then return new; end if;
  if tg_op = 'UPDATE' then
    if old.locked then return new; end if;
  end if;
  begin
    perform ftv_feed_post(ftv_my_player(), '🔒', '{who} locked {link}. They match the paper cards.',
      case new.day when 'fri' then 'Friday’s scores' else 'Saturday’s scores' end, '#live', null);
  end;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'feed_lock') then
    create trigger feed_lock after insert or update on public.day_locks for each row execute function public.ftv_feed_lock();
  end if;
end $$;
