-- =====================================================================
--  サーフィン行こ  追加SQL その9: 募集の案内文
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  変更点:
--   - 主催者が「募集の案内文」(トリップの詳細・費用・持ち物など)を書ける
--   - 声をかけられた人の募集ページに、その案内文が表示される
--     (参加者用の「旅のしおり」とは別。しおりは確定した人だけが見られる)
-- =====================================================================

alter table public.trips add column if not exists recruit_note text;

-- 主催者: 募集の案内文を書き換える
create or replace function public.set_recruit_note(p_trip uuid, p_note text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  if char_length(coalesce(p_note, '')) > 3000 then raise exception '3000文字以内にしてください'; end if;
  update public.trips set recruit_note = nullif(trim(coalesce(p_note, '')), '') where id = p_trip;
end;
$$;

-- 声をかけられた人向けの一覧に、案内文を追加
drop function if exists public.my_recruits();
create or replace function public.my_recruits()
returns table (trip_id uuid, name text, confirmed_start date, confirmed_end date, capacity int, remaining int,
               recruit_open boolean, recruit_deadline date, my_status text, my_comment text,
               my_result text, waitlist_order int, joined boolean, recruit_note text)
language sql stable security definer
set search_path = public
as $$
  select t.id, t.name, t.confirmed_start, t.confirmed_end, t.capacity, public.trip_remaining(t.id),
         t.recruit_open, t.recruit_deadline, i.status, i.comment, i.result, i.waitlist_order,
         exists (select 1 from public.trip_members tm where tm.trip_id = t.id and tm.member_id = i.member_id),
         t.recruit_note
    from public.trip_invites i join public.trips t on t.id = i.trip_id
   where i.member_id = public.current_member_id()
     and (t.recruit_open or i.result is not null)
   order by t.confirmed_start;
$$;

revoke all on function public.set_recruit_note(uuid, text) from public, anon;
revoke all on function public.my_recruits()                from public, anon;
grant execute on function public.set_recruit_note(uuid, text) to authenticated;
grant execute on function public.my_recruits()                to authenticated;

select 'OK' as result;
