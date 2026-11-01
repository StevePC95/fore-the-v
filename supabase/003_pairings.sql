-- Fore the V: captains pick the fourballs for each day.
-- Run once in Supabase: SQL Editor > New query > paste all > Run.
-- Captains (Brandon, Guy) set their own team; Steve (admin) can set either team.

alter table public.players add column if not exists is_captain boolean not null default false;
update public.players set is_captain = (id in ('brandon', 'guy'));

create table if not exists public.pairings (
  day        text not null check (day in ('fri','sat')),
  player_id  text not null references public.players (id),
  fourball   int  not null check (fourball in (1, 2)),
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (day, player_id)
);
alter table public.pairings enable row level security;
drop policy if exists "Anyone can read pairings" on public.pairings;
create policy "Anyone can read pairings" on public.pairings for select using (true);

-- Who's signed in, now including captaincy
create or replace function public.ftv_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('player_id', m.player_id, 'name', m.display_name, 'short', coalesce(p.short, m.display_name),
                            'team', p.team, 'tour_access', m.tour_access, 'is_admin', coalesce(p.is_admin, false),
                            'is_captain', coalesce(p.is_captain, false))
  from members m left join players p on p.id = m.player_id
  where m.user_id = auth.uid();
$$;

-- Save one team's split for one day: p = {"steve":1,"nic":2,"luke":1,"brandon":2}
create or replace function public.ftv_set_pairings(p_day text, p_team text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me players; k text; n1 int := 0; n2 int := 0; v int;
begin
  select pl.* into me from members m join players pl on pl.id = m.player_id
   where m.user_id = auth.uid() and m.tour_access;
  if not found then raise exception 'not_allowed' using errcode = '42501'; end if;
  if not (me.is_admin or (me.is_captain and me.team = p_team)) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_day not in ('fri','sat') or p_team not in ('in','co') then raise exception 'bad_input'; end if;

  -- must be exactly that team's 4 players, two in each fourball
  if (select count(*) from jsonb_object_keys(p)) <> 4
     or exists (select 1 from jsonb_object_keys(p) j(key)
                where not exists (select 1 from players where id = j.key and team = p_team)) then
    raise exception 'bad_players';
  end if;
  for k in select key from jsonb_object_keys(p) j(key) loop
    v := (p->>k)::int;
    if v = 1 then n1 := n1 + 1; elsif v = 2 then n2 := n2 + 1; else raise exception 'bad_input'; end if;
  end loop;
  if n1 <> 2 or n2 <> 2 then raise exception 'two_each'; end if;

  insert into pairings (day, player_id, fourball, updated_by, updated_at)
  select p_day, key, (p->>key)::int, me.short, now() from jsonb_object_keys(p) j(key)
  on conflict (day, player_id) do update
    set fourball = excluded.fourball, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end $$;

revoke all on function public.ftv_set_pairings(text, text, jsonb) from public;
grant execute on function public.ftv_set_pairings(text, text, jsonb) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.pairings;
exception when duplicate_object then null; end $$;
