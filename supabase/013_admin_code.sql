-- Fore the V: Steve's own sign-in code.
-- Run once in Supabase: SQL Editor > New query > paste all > Run. Safe to run again.
--  * Signing in as an admin (Steve) always needs a code: his personal code once it's set,
--    the shared Tour V code until then. The shared code stops working for him once his own is set.
--  * The other 7 are unchanged: the shared Tour V code is optional and unlocks scoring.
--  * Set or change the code (pick your own, keep it out of the chat and this repo):
--      insert into public.admin_codes (player_id, code) values ('steve', 'YOUR-CODE')
--      on conflict (player_id) do update set code = excluded.code;

create table if not exists public.admin_codes (
  player_id text primary key references public.players (id),
  code      text not null check (length(code) >= 4)
);
alter table public.admin_codes enable row level security;   -- no policies: nobody can read it from the app

create or replace function public.ftv_code_ok(p_player text, p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select nullif(trim(coalesce(p_code, '')), '') is not null and
         case when exists (select 1 from admin_codes where player_id = p_player)
              then p_code = (select code from admin_codes where player_id = p_player)
              else p_code = (select pin from tour_secret where id = 1) end;
$$;
revoke all on function public.ftv_code_ok(text, text) from public, anon, authenticated;

create or replace function public.ftv_join(p_code text, p_player text, p_name text default null, p_tour_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pl players; tour_ok boolean := false; nm text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not ftv_check_group(p_code) then raise exception 'bad_code' using errcode = '28P01'; end if;
  if p_player is not null then
    select * into pl from players where id = p_player;
    if not found then raise exception 'bad_player'; end if;
    if pl.is_admin then                                           -- Steve: his code is compulsory
      if not ftv_code_ok(pl.id, p_tour_code) then raise exception 'bad_tour_code' using errcode = '28P01'; end if;
      tour_ok := true;
    elsif pl.team is not null and nullif(trim(coalesce(p_tour_code, '')), '') is not null then
      if not ftv_code_ok(pl.id, p_tour_code) then raise exception 'bad_tour_code' using errcode = '28P01'; end if;
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
grant execute on function public.ftv_join(text, text, text, text) to authenticated;

create or replace function public.ftv_unlock(p_tour_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl players;
begin
  select p.* into pl from members m join players p on p.id = m.player_id where m.user_id = auth.uid();
  if not found or pl.team is null then raise exception 'not_on_tour' using errcode = '42501'; end if;
  if not ftv_code_ok(pl.id, p_tour_code) then raise exception 'bad_tour_code' using errcode = '28P01'; end if;
  update members set tour_access = true where user_id = auth.uid();
  return ftv_me();
end $$;
grant execute on function public.ftv_unlock(text) to authenticated;

notify pgrst, 'reload schema';
