-- Fore the V: comments on each fully video (Log a Fully wall).
-- Safe to run more than once. Applied directly to Supabase on 4 Nov.
--  * Any signed-in member can read and post comments (max 280 characters).
--  * The commenter's name is filled in by the database from their profile (can't be faked).
--  * You can remove your own comments; Steve can remove anyone's.
--  * Removing a video removes its comments.

create table if not exists public.dop_comments (
  id           uuid primary key default gen_random_uuid(),
  video_id     uuid not null references public.dop_videos(id) on delete cascade,
  body         text not null check (length(trim(body)) between 1 and 280),
  posted_by    uuid not null default auth.uid(),
  posted_player text,
  posted_name  text,
  created_at   timestamptz not null default now()
);
create index if not exists dop_comments_video_idx on public.dop_comments (video_id, created_at);
alter table public.dop_comments enable row level security;

-- Stamp who wrote it from their sign-in, whatever the phone sends
create or replace function public.ftv_dop_comment_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.posted_by := auth.uid();
  new.body := trim(new.body);
  new.created_at := now();
  select m.player_id, coalesce(p.short, m.display_name)
    into new.posted_player, new.posted_name
    from members m left join players p on p.id = m.player_id
   where m.user_id = auth.uid();
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'dop_comments_stamp') then
    create trigger dop_comments_stamp before insert on public.dop_comments
      for each row execute function public.ftv_dop_comment_stamp();
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'dop_comments' and policyname = 'Members read fully comments') then
    create policy "Members read fully comments" on public.dop_comments for select to authenticated
      using (public.ftv_is_member());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'dop_comments' and policyname = 'Members post fully comments') then
    create policy "Members post fully comments" on public.dop_comments for insert to authenticated
      with check (public.ftv_is_member() and posted_by = auth.uid());
  end if;
  if not exists (select 1 from pg_policies where tablename = 'dop_comments' and policyname = 'Remove your own fully comments') then
    create policy "Remove your own fully comments" on public.dop_comments for delete to authenticated
      using (posted_by = auth.uid() or public.ftv_is_admin());
  end if;
end $$;

grant select, insert, delete on public.dop_comments to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.dop_comments;
exception when duplicate_object then null; end $$;
