-- Fore the V: wipe test data before the group gets the link.
-- Run in Supabase: SQL Editor > New query > paste all > Run.
-- Keeps: players, sign-ins (members), codes, course setup.
-- Clears: scores, Wolf calls, Wolf wheel spins, round locks, fourball pairs, old dop points, dop videos, photos.

delete from public.scores;
delete from public.wolf_calls;
delete from public.wolf_order;
delete from public.day_locks;
delete from public.pairings;        -- captains pick for real this week
delete from public.dops;            -- old dop-points log (no longer used)
delete from public.dop_videos;      -- test dop videos
delete from public.photos;          -- test photos

-- Check: every count below should be 0.
select 'scores' as what, count(*) from public.scores
union all select 'wolf_calls', count(*) from public.wolf_calls
union all select 'wolf_order', count(*) from public.wolf_order
union all select 'day_locks', count(*) from public.day_locks
union all select 'pairings', count(*) from public.pairings
union all select 'dops (old)', count(*) from public.dops
union all select 'dop_videos', count(*) from public.dop_videos
union all select 'photos', count(*) from public.photos
union all select 'files in dops bucket', count(*) from storage.objects where bucket_id = 'dops'
union all select 'files in photos bucket', count(*) from storage.objects where bucket_id = 'photos';
-- The last two show leftover video/photo FILES. Supabase won't let SQL delete files:
-- remove them in Storage > dops (and Storage > photos) > select all > Delete.
