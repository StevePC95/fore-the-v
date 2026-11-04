-- 015: Bookie sections (Steve, 4 Nov). Each market sits in a drop-down section on the Bookie tab.
-- Sections: weekend, friday, saturday, boks, other. Null / unknown shows under "Off the Course".
-- Safe to re-run.

alter table public.markets add column if not exists category text;

-- Steve only: move a market to a section.
create or replace function public.ftv_market_section(p_id uuid, p_cat text) returns void
language plpgsql security definer set search_path = public as $$
declare me players;
begin
  me := ftv_bookie_me();
  if not me.is_admin then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_cat is not null and p_cat not in ('weekend','friday','saturday','boks','other') then raise exception 'bad_section'; end if;
  update markets set category = p_cat where id = p_id;
end $$;
revoke all on function public.ftv_market_section(uuid, text) from public;
grant execute on function public.ftv_market_section(uuid, text) to authenticated;

-- Tag the markets set up on 4 Nov (matched by question).
update public.markets set category = case
  when question in ('Who wins the cup?','Who wins the Wooden Spoon?','Top individual points over both rounds?',
                    'Most gross birdies over the weekend?','Who picks up first?','Most 0s on the scorecard over the weekend?') then 'weekend'
  when question like 'Friday:%' then 'friday'
  when question like 'Saturday:%' then 'saturday'
  when question like 'Springboks vs Italy:%' then 'boks'
  else 'other' end
where category is null;
