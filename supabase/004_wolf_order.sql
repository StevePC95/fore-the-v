-- Fore the V: the Wolf wheel. Spins a random Wolf order for each Friday fourball.
-- Run once in Supabase: SQL Editor > New query > paste all > Run. (Needs 003_pairings.sql first.)
-- Order alternates teams: Team A, Team B, Team A (other player), Team B (other player), then repeats.
-- Holes 2-9 and 11-18 follow that order, so everyone is Wolf 4 times. Holes 1 and 10 have no Wolf.

create table if not exists public.wolf_order (
  day      text not null check (day in ('fri','sat')),
  fourball int  not null check (fourball in (1, 2)),
  players  text[] not null,        -- 4 player ids in Wolf order
  spun_by  text,
  spun_at  timestamptz not null default now(),
  primary key (day, fourball)
);
alter table public.wolf_order enable row level security;
drop policy if exists "Anyone can read the wolf order" on public.wolf_order;
create policy "Anyone can read the wolf order" on public.wolf_order for select using (true);

-- The random draw happens here, on the server, so nobody can fiddle it on their phone.
create or replace function public.ftv_spin_wolf(p_day text, p_fb int) returns text[]
language plpgsql security definer set search_path = public as $$
declare me players; ins text[]; cos text[]; ord text[];
begin
  select pl.* into me from members m join players pl on pl.id = m.player_id
   where m.user_id = auth.uid() and m.tour_access;
  if not found then raise exception 'not_allowed' using errcode = '42501'; end if;
  if exists (select 1 from wolf_order where day = p_day and fourball = p_fb) then
    raise exception 'already_spun';
  end if;

  select array_agg(pa.player_id order by random()) into ins
    from pairings pa join players pl on pl.id = pa.player_id
   where pa.day = p_day and pa.fourball = p_fb and pl.team = 'in';
  select array_agg(pa.player_id order by random()) into cos
    from pairings pa join players pl on pl.id = pa.player_id
   where pa.day = p_day and pa.fourball = p_fb and pl.team = 'co';
  if coalesce(array_length(ins, 1), 0) <> 2 or coalesce(array_length(cos, 1), 0) <> 2 then
    raise exception 'no_pairs';
  end if;

  if random() < 0.5 then ord := array[ins[1], cos[1], ins[2], cos[2]];
  else ord := array[cos[1], ins[1], cos[2], ins[2]];
  end if;

  insert into wolf_order (day, fourball, players, spun_by) values (p_day, p_fb, ord, me.short);
  return ord;
end $$;

-- Steve (admin) can wipe a spin if the fourballs change.
create or replace function public.ftv_reset_wolf(p_day text, p_fb int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from members m join players pl on pl.id = m.player_id
                  where m.user_id = auth.uid() and pl.is_admin) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from wolf_order where day = p_day and fourball = p_fb;
end $$;

revoke all on function public.ftv_spin_wolf(text, int) from public;
revoke all on function public.ftv_reset_wolf(text, int) from public;
grant execute on function public.ftv_spin_wolf(text, int) to authenticated;
grant execute on function public.ftv_reset_wolf(text, int) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.wolf_order;
exception when duplicate_object then null; end $$;
