-- =====================================================================
--  サーフィン行こ  追加SQL その2: トリップ調整帳
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「trips / trip_members / trip_availability」
--  の3行が出れば成功です。
--
--  ※ schema.sql(最初のSQL)を実行済みであることが前提です。
-- =====================================================================

-- ============ テーブル ============

-- トリップ(例: 「バリ 12月」)
create table if not exists public.trips (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(trim(name)) between 1 and 30),
  created_by uuid not null references public.members(id) on delete cascade,
  start_date date,            -- 目安の期間(任意)
  end_date   date,
  created_at timestamptz not null default now()
);

-- トリップの参加者(この人たちだけがトリップを見られる)
create table if not exists public.trip_members (
  trip_id   uuid not null references public.trips(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  primary key (trip_id, member_id)
);

-- トリップの回答(1日1行)
create table if not exists public.trip_availability (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references public.trips(id) on delete cascade,
  member_id  uuid not null references public.members(id) on delete cascade,
  date       date not null,
  intent     text not null check (intent in ('free','adjust','no')),
  note       text check (note is null or char_length(note) <= 200),
  updated_at timestamptz not null default now(),
  unique (trip_id, member_id, date)
);
create index if not exists trip_availability_trip_idx on public.trip_availability (trip_id);

drop trigger if exists trip_availability_updated_at on public.trip_availability;
create trigger trip_availability_updated_at
  before insert or update on public.trip_availability
  for each row execute function public.tg_availability_updated_at();


-- ============ ヘルパー ============

-- いまのメンバーがそのトリップの参加者か
create or replace function public.is_trip_member(p_trip uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.trip_members
     where trip_id = p_trip and member_id = public.current_member_id());
$$;

-- そのトリップを作った人(または管理者)か
create or replace function public.is_trip_owner(p_trip uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.trips
     where id = p_trip and created_by = public.current_member_id())
    or public.is_admin();
$$;


-- ============ 操作用の関数 ============

-- トリップを作る(作った人は自動で参加者に入る)
create or replace function public.create_trip(p_name text, p_member_ids uuid[])
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_me uuid := public.current_member_id();
  v_id uuid;
begin
  if v_me is null then raise exception 'ログインしていません'; end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then raise exception '名前を入れてください'; end if;

  insert into public.trips (name, created_by) values (trim(p_name), v_me) returning id into v_id;

  insert into public.trip_members (trip_id, member_id)
  select v_id, m.id from public.members m
   where m.id = v_me or m.id = any(coalesce(p_member_ids, '{}'))
  on conflict do nothing;

  return v_id;
end;
$$;

-- 参加者を入れ替える(作った人・管理者のみ。作った人は必ず残る)
create or replace function public.set_trip_members(p_trip uuid, p_member_ids uuid[])
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  select created_by into v_owner from public.trips where id = p_trip;

  delete from public.trip_members
   where trip_id = p_trip
     and member_id <> v_owner
     and not (member_id = any(coalesce(p_member_ids, '{}')));

  insert into public.trip_members (trip_id, member_id)
  select p_trip, m.id from public.members m
   where m.id = v_owner or m.id = any(coalesce(p_member_ids, '{}'))
  on conflict do nothing;
end;
$$;

-- 名前を変える(作った人・管理者のみ)
create or replace function public.rename_trip(p_trip uuid, p_name text)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then raise exception '名前を入れてください'; end if;
  update public.trips set name = trim(p_name) where id = p_trip;
end;
$$;

-- トリップを削除(作った人・管理者のみ。回答もまとめて消える)
create or replace function public.delete_trip(p_trip uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_trip_owner(p_trip) then raise exception 'トリップを作った人だけができる操作です'; end if;
  delete from public.trips where id = p_trip;
end;
$$;

revoke all on function public.is_trip_member(uuid)             from public, anon;
revoke all on function public.is_trip_owner(uuid)              from public, anon;
revoke all on function public.create_trip(text, uuid[])        from public, anon;
revoke all on function public.set_trip_members(uuid, uuid[])   from public, anon;
revoke all on function public.rename_trip(uuid, text)          from public, anon;
revoke all on function public.delete_trip(uuid)                from public, anon;

grant execute on function public.is_trip_member(uuid)           to authenticated;
grant execute on function public.is_trip_owner(uuid)            to authenticated;
grant execute on function public.create_trip(text, uuid[])      to authenticated;
grant execute on function public.set_trip_members(uuid, uuid[]) to authenticated;
grant execute on function public.rename_trip(uuid, text)        to authenticated;
grant execute on function public.delete_trip(uuid)              to authenticated;


-- ============ RLS ============

alter table public.trips             enable row level security;
alter table public.trip_members      enable row level security;
alter table public.trip_availability enable row level security;

-- trips: 参加者だけが見られる。作成・変更・削除は上の関数から
revoke all on public.trips from anon, authenticated;
grant select on public.trips to authenticated;

drop policy if exists trips_select on public.trips;
create policy trips_select on public.trips
  for select to authenticated
  using (public.is_trip_member(id));

-- trip_members: 参加者だけが見られる
revoke all on public.trip_members from anon, authenticated;
grant select on public.trip_members to authenticated;

drop policy if exists trip_members_select on public.trip_members;
create policy trip_members_select on public.trip_members
  for select to authenticated
  using (public.is_trip_member(trip_id));

-- trip_availability: 参加者は全員分を読める / 書けるのは自分の分だけ
revoke all on public.trip_availability from anon;
grant select, insert, update, delete on public.trip_availability to authenticated;

drop policy if exists trip_avail_select on public.trip_availability;
create policy trip_avail_select on public.trip_availability
  for select to authenticated
  using (public.is_trip_member(trip_id));

drop policy if exists trip_avail_insert on public.trip_availability;
create policy trip_avail_insert on public.trip_availability
  for insert to authenticated
  with check (member_id = public.current_member_id() and public.is_trip_member(trip_id));

drop policy if exists trip_avail_update on public.trip_availability;
create policy trip_avail_update on public.trip_availability
  for update to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id());

drop policy if exists trip_avail_delete on public.trip_availability;
create policy trip_avail_delete on public.trip_availability
  for delete to authenticated
  using (member_id = public.current_member_id() or public.is_admin());


-- 完了確認: 3行出れば成功
select table_name from information_schema.tables
 where table_schema = 'public' and table_name in ('trips','trip_members','trip_availability')
 order by 1;
