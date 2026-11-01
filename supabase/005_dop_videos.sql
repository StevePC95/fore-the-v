-- Fore the V: dops are for fun (no points) and get filmed.
-- Run once in Supabase: SQL Editor > New query > paste all > Run.
--  * Anyone signed in can post a dop video; only signed-in members can watch them.
--  * The Tour V code is now optional at sign-in. It only unlocks entering live scores
--    (and captains' picks / the Wolf wheel), and can be added later from the account sheet.

-- 1. Sign-in: Tour V code optional ------------------------------------------------
create or replace function public.ftv_join(p_code text, p_player text, p_name text default null, p_tour_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pl players; tour_ok boolean := false; nm text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not ftv_check_group(p_code) then raise exception 'bad_code' using errcode = '28P01'; end if;
  if p_player is not null then
    select * into pl from players where id = p_player;
    if not found then raise exception 'bad_player'; end if;
    if pl.team is not null and nullif(trim(coalesce(p_tour_code, '')), '') is not null then
      if p_tour_code <> (select pin from tour_secret where id = 1) then
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

-- Add the Tour V code later (unlocks live scoring on this phone)
create or replace function public.ftv_unlock(p_tour_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t text;
begin
  select pl.team into t from members m join players pl on pl.id = m.player_id where m.user_id = auth.uid();
  if t is null then raise exception 'not_on_tour' using errcode = '42501'; end if;
  if p_tour_code is null or p_tour_code <> (select pin from tour_secret where id = 1) then
    raise exception 'bad_tour_code' using errcode = '28P01';
  end if;
  update members set tour_access = true where user_id = auth.uid();
  return ftv_me();
end $$;
grant execute on function public.ftv_unlock(text) to authenticated;

-- 2. Dop videos -----------------------------------------------------------------
create table if not exists public.dop_videos (
  id          uuid primary key default gen_random_uuid(),
  drinker     text not null,            -- player id, or a typed name
  kind        text,                     -- down-down, pint, shot, other
  video_path  text not null unique,
  poster_path text,
  secs        numeric,
  posted_by   uuid not null default auth.uid(),
  posted_name text,
  created_at  timestamptz not null default now()
);
alter table public.dop_videos enable row level security;

create or replace function public.ftv_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members m join players p on p.id = m.player_id where m.user_id = auth.uid() and p.is_admin);
$$;

drop policy if exists "Members watch dops" on public.dop_videos;
drop policy if exists "Members post dops" on public.dop_videos;
drop policy if exists "Remove your own dops" on public.dop_videos;
create policy "Members watch dops" on public.dop_videos for select to authenticated using (public.ftv_is_member());
create policy "Members post dops" on public.dop_videos for insert to authenticated
  with check (public.ftv_is_member() and posted_by = auth.uid());
create policy "Remove your own dops" on public.dop_videos for delete to authenticated
  using (posted_by = auth.uid() or public.ftv_is_admin());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dops', 'dops', false, 52428800, array['video/mp4','video/webm','video/quicktime','image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "FTV members watch dops" on storage.objects;
drop policy if exists "FTV members upload dops" on storage.objects;
create policy "FTV members watch dops" on storage.objects for select to authenticated
  using (bucket_id = 'dops' and public.ftv_is_member());
create policy "FTV members upload dops" on storage.objects for insert to authenticated
  with check (bucket_id = 'dops' and public.ftv_is_member());

do $$ begin
  alter publication supabase_realtime add table public.dop_videos;
exception when duplicate_object then null; end $$;
