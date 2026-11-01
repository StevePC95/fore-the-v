-- Fore the V: the execs' shared board (Fines ideas + Planning).
-- Run once in Supabase: SQL Editor > New query > paste all > Run. (Needs 002 first.)
--  * Only Steve, Nic, Brandon and Guy (signed in on their phones) can see, add, tick or remove items.
--  * Boards: golf / general / random = fines; plan = planning checklist.
--  * Ticks and new items are shared between the four execs and update live.
--  * Safe to run again: the starter items only go in once.

create table if not exists public.exec_items (
  id         uuid primary key default gen_random_uuid(),
  board      text not null check (board in ('golf','general','random','plan')),
  title      text not null check (length(trim(title)) between 1 and 160),
  detail     text check (length(detail) <= 400),
  penalty    text check (length(penalty) <= 60),     -- fines: "1 dop", "R50"...
  who        text check (length(who) <= 60),          -- random fines: who did it; planning: who's on it
  link       text,                                    -- planning: where in the app to go
  link_label text,
  done       boolean not null default false,          -- planning: done; random fine: dealt with at the fines session
  seed       text unique,                             -- starter items only
  sort       int not null default 100,
  added_by   text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.ftv_is_exec() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where user_id = auth.uid() and player_id in ('steve','nic','brandon','guy'));
$$;
grant execute on function public.ftv_is_exec() to authenticated;

alter table public.exec_items enable row level security;
drop policy if exists "Execs read" on public.exec_items;
drop policy if exists "Execs add" on public.exec_items;
drop policy if exists "Execs edit" on public.exec_items;
drop policy if exists "Execs remove" on public.exec_items;
create policy "Execs read"   on public.exec_items for select to authenticated using (public.ftv_is_exec());
create policy "Execs add"    on public.exec_items for insert to authenticated with check (public.ftv_is_exec());
create policy "Execs edit"   on public.exec_items for update to authenticated using (public.ftv_is_exec()) with check (public.ftv_is_exec());
create policy "Execs remove" on public.exec_items for delete to authenticated using (public.ftv_is_exec());

-- Starter items: the draft fines and the current planning list
insert into public.exec_items (seed, board, title, detail, penalty, who, link, link_label, sort, added_by) values
  ('g1','golf','Air shot','Swing, miss, pretend it was a practice swing','1 dop',null,null,null,10,'Steve'),
  ('g2','golf','Putt left short','Never up, never in','Finish your drink',null,null,null,20,'Steve'),
  ('g3','golf','Ball in the water','Per ball. Yes, per ball.','1 dop',null,null,null,30,'Steve'),
  ('g4','golf','Blind Wolf, lost','Greed has a price','1 dop',null,null,null,40,'Steve'),
  ('n1','general','Moaning about your handicap','Applies on and off the course','R TBC',null,null,null,10,'Steve'),
  ('n2','general','Late to the car or tee','Saturday 07:30 is not a suggestion','R TBC',null,null,null,20,'Steve'),
  ('n3','general','Talking about work','Nobody cares about your Q4','1 dop',null,null,null,30,'Steve'),
  ('r1','plan','Captains: pick the fourballs','Brandon and Guy, both days.',null,'Captains','#courses','Open Courses',10,'Steve'),
  ('r2','plan','Guy: message Steve about “the neutraliser”','The last open Wolf question.',null,'Guy','#formats','Open Wolf rules',20,'Steve'),
  ('r3','plan','Steve: finalise fines, awards and side bets','The Fines tab is hidden until it’s done.',null,'Steve','#fines','Open Fines',30,'Steve'),
  ('r4','plan','Book Hennie’s for 8 (Saturday rugby)','Cancel on Saturday morning if we stay at the Jackal Creek clubhouse.',null,'Execs','https://www.google.com/maps/search/?api=1&query=Hennie%27s+Randburg','Find Hennie’s ↗',40,'Steve'),
  ('r5','plan','Book the transport','Uber or other for every trip. Brandon drives on Saturday only.',null,'Execs','#schedule','See the trips',50,'Steve'),
  ('s4','plan','Kitty','How much each, what it covers and who holds it.',null,'Execs','#logistics','Open Logistics',60,'Steve'),
  ('s5','plan','House food and booze','Saturday breakie (toast, cereal) and pizzas.',null,'Execs','#logistics','Open Logistics',70,'Steve'),
  ('s6','plan','Losing team forfeit','What the losers have to do.',null,'Steve','#fines','Open Fines',80,'Steve')
on conflict (seed) do nothing;

do $$ begin alter publication supabase_realtime add table public.exec_items; exception when duplicate_object then null; end $$;

-- Check: should show golf 4, general 3, plan 8 the first time.
select board, count(*) from public.exec_items group by board order by board;
