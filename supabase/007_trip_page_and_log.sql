-- =====================================================================
--  サーフィン行こ  追加SQL その7: トリップ確定ページ・掲示板・サーフィン記録
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  変更点:
--   - トリップを「確定」できる(作った人だけ)。確定した日程を保存
--   - 確定トリップのページ: 旅のしおり(参加者全員が編集可)+ 掲示板
--   - 掲示板の未読数(赤丸用)
--   - サーフィン記録(surf_log): 日付が過ぎた「行く」の日と、確定トリップの日を
--     「行った日」として確定保存する。あとから予定を消しても記録は残る
--     (ランキングなど、今後の集計の元データになる)
-- =====================================================================

-- 日本時間の「今日」
create or replace function public.jst_today()
returns date
language sql stable
as $$ select (now() at time zone 'Asia/Tokyo')::date; $$;


-- ============ トリップ: 確定日程・旅のしおり ============
alter table public.trips add column if not exists confirmed_start  date;
alter table public.trips add column if not exists confirmed_end    date;
alter table public.trips add column if not exists confirmed_at     timestamptz;
alter table public.trips add column if not exists notes            text;
alter table public.trips add column if not exists notes_updated_at timestamptz;
alter table public.trips add column if not exists notes_updated_by uuid references public.members(id) on delete set null;

-- 確定(作った人だけ)
create or replace function public.confirm_trip(p_trip uuid, p_start date, p_end date)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.trips where id = p_trip and created_by = public.current_member_id()) then
    raise exception 'トリップを作った人だけが確定できます';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception '日程が正しくありません';
  end if;
  if p_end - p_start > 60 then
    raise exception '確定できるのは60日以内の日程です';
  end if;
  update public.trips
     set confirmed_start = p_start, confirmed_end = p_end, confirmed_at = now()
   where id = p_trip;
end;
$$;

-- 確定の取り消し(作った人だけ)
create or replace function public.unconfirm_trip(p_trip uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.trips where id = p_trip and created_by = public.current_member_id()) then
    raise exception 'トリップを作った人だけが取り消せます';
  end if;
  update public.trips
     set confirmed_start = null, confirmed_end = null, confirmed_at = null
   where id = p_trip;
end;
$$;

-- 旅のしおりを書き換える(参加者なら誰でも)
create or replace function public.update_trip_notes(p_trip uuid, p_notes text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_trip_member(p_trip) then raise exception '参加者だけが編集できます'; end if;
  if char_length(coalesce(p_notes, '')) > 3000 then raise exception '3000文字以内にしてください'; end if;
  update public.trips
     set notes = nullif(trim(coalesce(p_notes, '')), ''),
         notes_updated_at = now(), notes_updated_by = public.current_member_id()
   where id = p_trip;
end;
$$;


-- ============ 掲示板 ============
create table if not exists public.trip_posts (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references public.trips(id) on delete cascade,
  member_id  uuid not null references public.members(id) on delete cascade,
  body       text not null check (char_length(trim(body)) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists trip_posts_trip_idx on public.trip_posts (trip_id, created_at);

-- 掲示板を最後に見た時刻(赤丸用)
create table if not exists public.trip_post_seen (
  trip_id   uuid not null references public.trips(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  seen_at   timestamptz not null default now(),
  primary key (trip_id, member_id)
);

alter table public.trip_posts     enable row level security;
alter table public.trip_post_seen enable row level security;

revoke all on public.trip_posts from anon, authenticated;
grant select, insert, delete on public.trip_posts to authenticated;

-- 読む・書く: 参加者だけ / 消す: 自分の投稿(トリップを作った人・管理者はどれでも)
drop policy if exists trip_posts_select on public.trip_posts;
create policy trip_posts_select on public.trip_posts
  for select to authenticated
  using (public.is_trip_member(trip_id));

drop policy if exists trip_posts_insert on public.trip_posts;
create policy trip_posts_insert on public.trip_posts
  for insert to authenticated
  with check (member_id = public.current_member_id() and public.is_trip_member(trip_id));

drop policy if exists trip_posts_delete on public.trip_posts;
create policy trip_posts_delete on public.trip_posts
  for delete to authenticated
  using (member_id = public.current_member_id() or public.is_trip_owner(trip_id));

revoke all on public.trip_post_seen from anon, authenticated;
grant select, insert, update on public.trip_post_seen to authenticated;

drop policy if exists trip_post_seen_own on public.trip_post_seen;
create policy trip_post_seen_own on public.trip_post_seen
  for all to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id() and public.is_trip_member(trip_id));

-- 自分が参加しているトリップごとの未読数(他の人の新しい投稿)
create or replace function public.trip_unread()
returns table (trip_id uuid, unread int)
language sql stable security definer
set search_path = public
as $$
  select tm.trip_id,
         (select count(*)::int from public.trip_posts p
           where p.trip_id = tm.trip_id
             and p.member_id <> tm.member_id
             and p.created_at > coalesce(
               (select s.seen_at from public.trip_post_seen s
                 where s.trip_id = tm.trip_id and s.member_id = tm.member_id), '-infinity'))
    from public.trip_members tm
   where tm.member_id = public.current_member_id();
$$;


-- ============ サーフィン記録 ============
create table if not exists public.surf_log (
  id         bigint generated always as identity primary key,
  member_id  uuid not null references public.members(id) on delete cascade,
  date       date not null,
  source     text not null check (source in ('sea','pool','abroad','trip')),
  trip_id    uuid references public.trips(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (member_id, date, source)
);
create index if not exists surf_log_member_idx on public.surf_log (member_id, date);

alter table public.surf_log enable row level security;
revoke all on public.surf_log from anon, authenticated;
grant select on public.surf_log to authenticated;

-- 見られるのは自分の記録だけ(ランキングなどは今後、集計用の関数で出す)
drop policy if exists surf_log_own on public.surf_log;
create policy surf_log_own on public.surf_log
  for select to authenticated
  using (member_id = public.current_member_id());

-- 日付が過ぎた分を記録に確定する(何度呼んでも同じ結果。アプリ起動時と自動pingで呼ぶ)
create or replace function public.snapshot_surf_log()
returns int
language plpgsql security definer
set search_path = public
as $$
declare
  v_today date := public.jst_today();
  n1 int; n2 int;
begin
  -- 海・プール・海外の「行く」
  insert into public.surf_log (member_id, date, source)
  select a.member_id, a.date, a.genre
    from public.availability a
   where a.intent = 'go' and a.date < v_today
  on conflict (member_id, date, source) do nothing;
  get diagnostics n1 = row_count;

  -- 確定トリップの日(その日に「行けない」と答えた人は除く)
  insert into public.surf_log (member_id, date, source, trip_id)
  select tm.member_id, d::date, 'trip', t.id
    from public.trips t
    join public.trip_members tm on tm.trip_id = t.id
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

-- 自分の記録の集計
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
  where member_id = public.current_member_id();
$$;


-- ============ 権限 ============
revoke all on function public.jst_today()                          from public;
revoke all on function public.confirm_trip(uuid, date, date)       from public, anon;
revoke all on function public.unconfirm_trip(uuid)                 from public, anon;
revoke all on function public.update_trip_notes(uuid, text)        from public, anon;
revoke all on function public.trip_unread()                        from public, anon;
revoke all on function public.snapshot_surf_log()                  from public;
revoke all on function public.my_surf_stats()                      from public, anon;

grant execute on function public.jst_today()                       to anon, authenticated;
grant execute on function public.confirm_trip(uuid, date, date)    to authenticated;
grant execute on function public.unconfirm_trip(uuid)              to authenticated;
grant execute on function public.update_trip_notes(uuid, text)     to authenticated;
grant execute on function public.trip_unread()                     to authenticated;
grant execute on function public.snapshot_surf_log()               to anon, authenticated;  -- 自動pingからも呼ぶ
grant execute on function public.my_surf_stats()                   to authenticated;

-- すでに過ぎた分を、いま記録しておく
select public.snapshot_surf_log();

-- 完了確認
select 'OK' as result;
