-- Fore the V: fines go live (6 Nov, Steve).
--  * Everyone signed in can read the golf / general / random fines (planning stays execs-only).
--  * Anyone signed in can log a Random fine (who did what). Rules, ticks and removals stay with the execs.
--  * Safe to run again.

create or replace function public.ftv_is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members where user_id = auth.uid());
$$;
grant execute on function public.ftv_is_member() to authenticated;

drop policy if exists "Members read fines" on public.exec_items;
create policy "Members read fines" on public.exec_items for select to authenticated
  using (board in ('golf','general','random') and public.ftv_is_member());

drop policy if exists "Members log random fines" on public.exec_items;
create policy "Members log random fines" on public.exec_items for insert to authenticated
  with check (board = 'random' and done = false and public.ftv_is_member());

update public.exec_items set done = true, updated_at = now() where seed = 'r3';
