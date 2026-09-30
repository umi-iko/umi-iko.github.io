-- =====================================================================
--  サーフィン行こ  追加SQL その8: 「行った」の修正・ボートトリップ(定員あり)
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  変更点:
--   - 「行った」を自分で塗れる/外せる(過去の日)。外した日は自動記録でも復活しない
--   - トリップに「ボートトリップ(定員あり)」を追加
--       コア調整(コアメンバーだけ) → 募集(指定した人だけ、コアメンバーは見えない)
--       → 主催者が定員まで選んで確定。キャンセル待ちあり。回答期限あり
-- =====================================================================


-- ============ 「行った」の修正 ============
-- went=false の行 = 「行かなかった」。自動記録(snapshot)は on conflict do nothing なので復活しない
alter table public.surf_log add column if not exists went boolean not null default true;
alter table public.surf_log add column if not exists updated_at timestamptz not null default now();

grant insert, update on public.surf_log to authenticated;

drop policy if exists surf_log_insert on public.surf_log;
create policy surf_log_insert on public.surf_log
  for insert to authenticated
  with check (member_id = public.current_member_id() and date < public.jst_today());

drop policy if exists surf_log_update on public.surf_log;
create policy surf_log_update on public.surf_log
  for update to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id());

-- 「行った」で塗る(過去の日だけ)
create or replace function public.mark_went(p_source text, p_dates date[], p_trip uuid default null)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_me uuid := public.current_member_id();
begin
  if v_me is null then raise exception 'ログインしていません'; end if;
  if p_source not in ('sea','pool','abroad','trip') then raise exception '種類が正しくありません'; end if;
  insert into public.surf_log (member_id, date, source, trip_id, went)
  select v_me, d, p_source, p_trip, true
    from unnest(p_dates) d
   where d < public.jst_today()
  on conflict (member_id, date, source) do update set went = true, updated_at = now();
end;
$$;

-- 「行かなかった」にする(過去の日だけ)。記録は残して went=false にする
create or replace function public.unmark_went(p_source text, p_dates date[])
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_me uuid := public.current_member_id();
begin
  if v_me is null then raise exception 'ログインしていません'; end if;
  insert into public.surf_log (member_id, date, source, went)
  select v_me, d, p_source, false
    from unnest(p_dates) d
   where d < public.jst_today()
  on conflict (member_id, date, source) do update set went = false, updated_at = now();
end;
$$;

-- 集計は went=true だけ数える
create or replace function public.my_surf_stats()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_build_object(
    'total',     count(distinct date),
    'this_year', count(distinct date) filter (where extract(year from date) = extract(year from public.jst_today())),
    'sea',       count(*) filter (where source = 'sea'),
    'pool',      count(*) filter (where source = 'pool'),
    'abroad',    count(*) filter (where source = 'abroad'),
    'trip',      count(distinct date) filter (where source = 'trip'),
    'last_date', max(date))
  from public.surf_log
  where member_id = public.current_member_id() and went;
$$;


-- ============ ボートトリップ(定員あり) ============
alter table public.trips add column if not exists kind text not null default 'flex' check (kind in ('flex','boat'));
alter table public.trips add column if not exists capacity int check (capacity is null or capacity between 1 and 200);
alter table public.trips add column if not exists recruit_open boolean not null default false;
alter table public.trips add column if not exists recruit_deadline date;

-- 参加者の種類: core=コアメンバー(調整に参加) / joined=募集で確定した人
-- going: コアメンバーが実際に行くか(募集の残り枠の計算に使う)
alter table public.trip_members add column if not exists role text not null default 'core' check (role in ('core','joined'));
alter table public.trip_members add column if not exists going boolean not null default true;

-- 募集(声をかけた人と、その回答)
create table if not exists public.trip_invites (
  trip_id        uuid not null references public.trips(id) on delete cascade,
  member_id      uuid not null references public.members(id) on delete cascade,
  status         text not null default 'invited'
                 check (status in ('invited','go','positive','maybe','no')),
  comment        text check (comment is null or char_length(comment) <= 200),
  responded_at   timestamptz,
  result         text check (result is null or result in ('confirmed','waitlist')),
  waitlist_order int,
  invited_at     timestamptz not null default now(),
  primary key (trip_id, member_id)
);
alter table public.trip_invites enable row level security;
revoke all on public.trip_invites from anon, authenticated;   -- 直接は触らせない(関数だけ)

-- コアメンバーか
create or replace function public.is_trip_core(p_trip uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.trip_members
                  where trip_id = p_trip and member_id = public.current_member_id() and role = 'core');
$$;

-- 調整の回答(trip_availability)は、コアメンバーだけが全員分を見られる。
-- 募集で入った人(joined)は自分の分だけ(=コア調整の中身は見えない)
drop policy if exists trip_avail_select on public.trip_availability;
create policy trip_avail_select on public.trip_availability
  for select to authenticated
  using (public.is_trip_member(trip_id)
         and (member_id = public.current_member_id() or public.is_trip_core(trip_id)));

-- 残り枠 = 定員 − 行くコアメンバー − 確定した募集メンバー
create or replace function public.trip_remaining(p_trip uuid)
returns int
language sql stable security definer
set search_path = public
as $$
  select coalesce(t.capacity, 0)
       - (select count(*)::int from public.trip_members m where m.trip_id = t.id and m.going)
    from public.trips t where t.id = p_trip;
$$;

-- 作成(種類と定員つき)
create or replace function public.create_trip2(p_name text, p_member_ids uuid[], p_kind text, p_capacity int)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_kind not in ('flex','boat') then raise exception '種類が正しくありません'; end if;
  if p_kind = 'boat' and (p_capacity is null or p_capacity < 1) then raise exception '定員を入れてください'; end if;
  v_id := public.create_trip(p_name, p_member_ids);
  update public.trips set kind = p_kind, capacity = case when p_kind = 'boat' then p_capacity else null end where id = v_id;
  return v_id;
end;
$$;

-- 主催者: 定員を変える
create or replace function public.set_trip_capacity(p_trip uuid, p_capacity int)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  if p_capacity is null or p_capacity < 1 then raise exception '定員は1人以上にしてください'; end if;
  update public.trips set capacity = p_capacity where id = p_trip;
end;
$$;

-- 主催者: コアメンバーのうち「行く」人を決める
create or replace function public.set_core_going(p_trip uuid, p_going uuid[])
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  update public.trip_members
     set going = (member_id = any(coalesce(p_going, '{}')))
   where trip_id = p_trip and role = 'core';
end;
$$;

-- 主催者: 声をかける人を入れ替える(コアメンバーは対象外。すでに結果が出た人は残す)
create or replace function public.set_recruits(p_trip uuid, p_member_ids uuid[])
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  delete from public.trip_invites
   where trip_id = p_trip and result is null
     and not (member_id = any(coalesce(p_member_ids, '{}')));
  insert into public.trip_invites (trip_id, member_id)
  select p_trip, m.id from public.members m
   where m.id = any(coalesce(p_member_ids, '{}'))
     and not exists (select 1 from public.trip_members tm where tm.trip_id = p_trip and tm.member_id = m.id)
  on conflict do nothing;
end;
$$;

-- 主催者: 募集を開始/期限を変更(日程確定・定員が前提)
create or replace function public.open_recruit(p_trip uuid, p_deadline date)
returns void
language plpgsql security definer
set search_path = public
as $$
declare t public.trips;
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  select * into t from public.trips where id = p_trip;
  if t.kind <> 'boat' then raise exception '定員ありのトリップだけ募集できます'; end if;
  if t.confirmed_start is null then raise exception '先に日程を確定してください'; end if;
  if t.capacity is null then raise exception '定員を設定してください'; end if;
  if p_deadline is not null and p_deadline < public.jst_today() then raise exception '回答期限は今日以降にしてください'; end if;
  update public.trips set recruit_open = true, recruit_deadline = p_deadline where id = p_trip;
end;
$$;

-- 主催者: 募集を締め切る
create or replace function public.close_recruit(p_trip uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  update public.trips set recruit_open = false where id = p_trip;
end;
$$;

-- 主催者: 回答の一覧
create or replace function public.recruit_responses(p_trip uuid)
returns table (member_id uuid, name text, status text, comment text, responded_at timestamptz,
               result text, waitlist_order int)
language sql stable security definer
set search_path = public
as $$
  select i.member_id, m.name, i.status, i.comment, i.responded_at, i.result, i.waitlist_order
    from public.trip_invites i join public.members m on m.id = i.member_id
   where i.trip_id = p_trip and public.is_trip_owner(p_trip)
   order by case i.result when 'confirmed' then 0 when 'waitlist' then 1 else 2 end,
            i.waitlist_order nulls last,
            case i.status when 'go' then 0 when 'positive' then 1 when 'maybe' then 2 when 'invited' then 3 else 4 end,
            i.responded_at nulls last;
$$;

-- 主催者: 確定メンバーとキャンセル待ちを決める(定員を超えたらエラー)
create or replace function public.select_participants(p_trip uuid, p_confirmed uuid[], p_waitlist uuid[])
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_cap int; v_core int; v_conf int;
  v_id uuid; i int := 0;
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  select capacity into v_cap from public.trips where id = p_trip;
  select count(*) into v_core from public.trip_members where trip_id = p_trip and role = 'core' and going;
  v_conf := coalesce(array_length(p_confirmed, 1), 0);
  if v_cap is not null and v_core + v_conf > v_cap then
    raise exception '定員(%人)を超えています(コア%人 + 確定%人)', v_cap, v_core, v_conf;
  end if;

  update public.trip_invites set result = null, waitlist_order = null where trip_id = p_trip;
  update public.trip_invites set result = 'confirmed', waitlist_order = null
   where trip_id = p_trip and member_id = any(coalesce(p_confirmed, '{}'));
  foreach v_id in array coalesce(p_waitlist, '{}') loop
    i := i + 1;
    update public.trip_invites set result = 'waitlist', waitlist_order = i
     where trip_id = p_trip and member_id = v_id;
  end loop;

  -- 確定した人は参加者(joined)に。外れた人は参加者から外す
  insert into public.trip_members (trip_id, member_id, role, going)
  select p_trip, member_id, 'joined', true from public.trip_invites
   where trip_id = p_trip and result = 'confirmed'
  on conflict (trip_id, member_id) do nothing;
  delete from public.trip_members tm
   where tm.trip_id = p_trip and tm.role = 'joined'
     and not exists (select 1 from public.trip_invites i
                      where i.trip_id = p_trip and i.member_id = tm.member_id and i.result = 'confirmed');
end;
$$;

-- 声をかけられた人: 自分宛ての募集の一覧(コアメンバーや他の回答者は含めない)
create or replace function public.my_recruits()
returns table (trip_id uuid, name text, confirmed_start date, confirmed_end date, capacity int, remaining int,
               recruit_open boolean, recruit_deadline date, my_status text, my_comment text,
               my_result text, waitlist_order int, joined boolean)
language sql stable security definer
set search_path = public
as $$
  select t.id, t.name, t.confirmed_start, t.confirmed_end, t.capacity, public.trip_remaining(t.id),
         t.recruit_open, t.recruit_deadline, i.status, i.comment, i.result, i.waitlist_order,
         exists (select 1 from public.trip_members tm where tm.trip_id = t.id and tm.member_id = i.member_id)
    from public.trip_invites i join public.trips t on t.id = i.trip_id
   where i.member_id = public.current_member_id()
     and (t.recruit_open or i.result is not null)
   order by t.confirmed_start;
$$;

-- 声をかけられた人: 回答する(期限内・募集中だけ)
create or replace function public.respond_recruit(p_trip uuid, p_status text, p_comment text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare t public.trips;
begin
  if p_status not in ('go','positive','maybe','no') then raise exception '回答が正しくありません'; end if;
  select * into t from public.trips where id = p_trip;
  if not t.recruit_open then raise exception '募集は締め切られています'; end if;
  if t.recruit_deadline is not null and t.recruit_deadline < public.jst_today() then raise exception '回答期限を過ぎています'; end if;
  update public.trip_invites
     set status = p_status, comment = nullif(trim(coalesce(p_comment, '')), ''), responded_at = now()
   where trip_id = p_trip and member_id = public.current_member_id();
  if not found then raise exception 'この募集の対象ではありません'; end if;
end;
$$;

-- 主催者: 募集の状況(要約カード用)
create or replace function public.recruit_summary(p_trip uuid)
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select case when public.is_trip_owner(p_trip) then jsonb_build_object(
    'invited',   (select count(*) from public.trip_invites where trip_id = p_trip),
    'go',        (select count(*) from public.trip_invites where trip_id = p_trip and status = 'go'),
    'positive',  (select count(*) from public.trip_invites where trip_id = p_trip and status = 'positive'),
    'maybe',     (select count(*) from public.trip_invites where trip_id = p_trip and status = 'maybe'),
    'no',        (select count(*) from public.trip_invites where trip_id = p_trip and status = 'no'),
    'unanswered',(select count(*) from public.trip_invites where trip_id = p_trip and status = 'invited'),
    'confirmed', (select count(*) from public.trip_invites where trip_id = p_trip and result = 'confirmed'),
    'waitlist',  (select count(*) from public.trip_invites where trip_id = p_trip and result = 'waitlist'),
    'remaining', public.trip_remaining(p_trip))
  else null end;
$$;

-- 記録: 確定トリップの日は「行く」メンバー(going)だけ
create or replace function public.snapshot_surf_log()
returns int
language plpgsql security definer
set search_path = public
as $$
declare
  v_today date := public.jst_today();
  n1 int; n2 int;
begin
  insert into public.surf_log (member_id, date, source)
  select a.member_id, a.date, a.genre
    from public.availability a
   where a.intent = 'go' and a.date < v_today
  on conflict (member_id, date, source) do nothing;
  get diagnostics n1 = row_count;

  insert into public.surf_log (member_id, date, source, trip_id)
  select tm.member_id, d::date, 'trip', t.id
    from public.trips t
    join public.trip_members tm on tm.trip_id = t.id and tm.going
    cross join lateral generate_series(t.confirmed_start, t.confirmed_end, interval '1 day') d
   where t.confirmed_start is not null
     and d::date < v_today
     and not exists (select 1 from public.trip_availability ta
                      where ta.trip_id = t.id and ta.member_id = tm.member_id
                        and ta.date = d::date and ta.intent = 'no')
  on conflict (member_id, date, source) do nothing;
  get diagnostics n2 = row_count;
  return n1 + n2;
end;
$$;


-- ============ 権限 ============
revoke all on function public.mark_went(text, date[], uuid)                 from public, anon;
revoke all on function public.unmark_went(text, date[])                     from public, anon;
revoke all on function public.is_trip_core(uuid)                            from public, anon;
revoke all on function public.trip_remaining(uuid)                          from public, anon;
revoke all on function public.create_trip2(text, uuid[], text, int)         from public, anon;
revoke all on function public.set_trip_capacity(uuid, int)                  from public, anon;
revoke all on function public.set_core_going(uuid, uuid[])                  from public, anon;
revoke all on function public.set_recruits(uuid, uuid[])                    from public, anon;
revoke all on function public.open_recruit(uuid, date)                      from public, anon;
revoke all on function public.close_recruit(uuid)                           from public, anon;
revoke all on function public.recruit_responses(uuid)                       from public, anon;
revoke all on function public.select_participants(uuid, uuid[], uuid[])     from public, anon;
revoke all on function public.my_recruits()                                 from public, anon;
revoke all on function public.respond_recruit(uuid, text, text)             from public, anon;
revoke all on function public.recruit_summary(uuid)                         from public, anon;

grant execute on function public.mark_went(text, date[], uuid)              to authenticated;
grant execute on function public.unmark_went(text, date[])                  to authenticated;
grant execute on function public.is_trip_core(uuid)                         to authenticated;
grant execute on function public.trip_remaining(uuid)                       to authenticated;
grant execute on function public.create_trip2(text, uuid[], text, int)      to authenticated;
grant execute on function public.set_trip_capacity(uuid, int)               to authenticated;
grant execute on function public.set_core_going(uuid, uuid[])               to authenticated;
grant execute on function public.set_recruits(uuid, uuid[])                 to authenticated;
grant execute on function public.open_recruit(uuid, date)                   to authenticated;
grant execute on function public.close_recruit(uuid)                        to authenticated;
grant execute on function public.recruit_responses(uuid)                    to authenticated;
grant execute on function public.select_participants(uuid, uuid[], uuid[])  to authenticated;
grant execute on function public.my_recruits()                              to authenticated;
grant execute on function public.respond_recruit(uuid, text, text)          to authenticated;
grant execute on function public.recruit_summary(uuid)                      to authenticated;

-- 完了確認
select 'OK' as result;
