-- Fore the V: add the last two Tour II players to the sign-in list.
-- Run once in Supabase: SQL Editor > New query > paste all > Run. Safe to run again.
-- They're past tourists (no team), so they can view, post photos and film dops, but not enter scores.
insert into public.players (id, name, short, team, is_admin, sort) values
  ('mansour', 'Dylan Mansour', 'Mansour', null, false, 28),
  ('matt',    'Matt Bruin',    'Matt',    null, false, 29)
on conflict (id) do update set name = excluded.name, short = excluded.short, sort = excluded.sort;

select id, name, short from public.players where team is null order by sort;
