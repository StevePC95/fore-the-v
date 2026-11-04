-- 016 · Photo tags (4 Nov 2026)
-- Photos now live in The 19th and get tagged with a tour or "Random".
-- album values: 't1' … 't5' (Tour I–V) or 'random'. Old 'general' photos show as Random.
-- Adds an optional caption, and lets you retag or recaption your own photos (Steve can fix any).
-- Safe to run more than once. Nothing is dropped or deleted.

alter table public.photos add column if not exists caption text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'photos_caption_len') then
    alter table public.photos add constraint photos_caption_len check (caption is null or char_length(caption) <= 140);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'photos_album_ok') then
    alter table public.photos add constraint photos_album_ok
      check (album in ('general','random','t1','t2','t3','t4','t5')) not valid;
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'photos' and policyname = 'Retag your own photos') then
    create policy "Retag your own photos" on public.photos for update to authenticated
      using (uploaded_by = auth.uid() or public.ftv_is_admin())
      with check (uploaded_by = auth.uid() or public.ftv_is_admin());
  end if;
end $$;

-- Only the tag and caption can be changed after upload
revoke update on public.photos from authenticated;
grant update (album, caption) on public.photos to authenticated;
