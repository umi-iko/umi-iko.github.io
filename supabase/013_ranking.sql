-- =====================================================================
--  サーフィン行こ  追加SQL その13: 行った日数のランキング
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  仲間全員の「行った日数」を多い順に並べます(同じ日に海とプールに行っても1日)。
--  p_year に年を渡すとその年だけ、null なら累計。
-- =====================================================================

drop function if exists public.surf_ranking(int);
create or replace function public.surf_ranking(p_year int default null)
returns table (member_id uuid, name text, days int, rank int)
language sql stable security definer
set search_path = public
as $$
  with counts as (
    select m.id as member_id, m.name,
           (select count(distinct l.date)::int from public.surf_log l
             where l.member_id = m.id and l.went
               and (p_year is null or extract(year from l.date) = p_year)) as days
      from public.members m
  )
  select member_id, name, days,
         rank() over (order by days desc)::int as rank
    from counts
   where public.current_member_id() is not null
   order by days desc, name;
$$;
revoke all on function public.surf_ranking(int) from public, anon;
grant execute on function public.surf_ranking(int) to authenticated;

select 'OK' as result;
