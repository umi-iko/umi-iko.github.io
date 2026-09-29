-- =====================================================================
--  サーフィン行こ  データベース定義 (Supabase)
--
--  使い方:
--    Supabase の「SQL Editor」→「New query」にこのファイルの中身を
--    全部貼り付けて「Run」を押すだけで完成します。
--    何度実行しても壊れないように書いてあります(やり直しOK)。
--
--  実行後、最初の管理者「Yama」(PIN: 0000)ができます。
--  ログインしたら、すぐにPINを変更してください。
-- =====================================================================

-- PINを暗号化(bcrypt)するための拡張機能
create extension if not exists pgcrypto with schema extensions;


-- =====================================================================
--  テーブル
-- =====================================================================

-- 仲間(メンバー)
create table if not exists public.members (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null unique check (char_length(trim(name)) between 1 and 20),
  pin_hash            text,
  is_admin            boolean not null default false,
  failed_attempts     int not null default 0,
  locked_until        timestamptz,
  pin_change_prompted boolean not null default false,  -- 初回の「PINを変えますか?」を出したか
  last_activity_at    timestamptz,                     -- 最後に予定を塗った/消した時刻(赤丸判定用)
  created_at          timestamptz not null default now()
);

-- ログイン状態(匿名ユーザー ⇔ メンバー の対応)
create table if not exists public.app_sessions (
  auth_uid   uuid primary key,
  member_id  uuid not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- 予定(1日1行)
create table if not exists public.availability (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references public.members(id) on delete cascade,
  genre      text not null check (genre in ('sea','pool','abroad')),
  date       date not null,
  intent     text not null check (intent ~ '^[a-z_]{1,30}$'),
  note       text check (note is null or char_length(note) <= 200),
  updated_at timestamptz not null default now(),
  unique (member_id, genre, date)
);
create index if not exists availability_date_idx on public.availability (date);

-- 誰が誰の予定を見るか
create table if not exists public.follows (
  follower_id uuid not null references public.members(id) on delete cascade,
  followee_id uuid not null references public.members(id) on delete cascade,
  primary key (follower_id, followee_id)
);

-- 赤丸判定用「最後に見た時刻」
create table if not exists public.last_seen (
  member_id   uuid not null references public.members(id) on delete cascade,
  followee_id uuid not null references public.members(id) on delete cascade,
  seen_at     timestamptz not null default now(),
  primary key (member_id, followee_id)
);

-- 自動ping用のダミーテーブル
create table if not exists public.keepalive (
  id        int primary key,
  pinged_at timestamptz not null default now()
);
insert into public.keepalive (id) values (1) on conflict (id) do nothing;


-- =====================================================================
--  RLS用ヘルパー関数
-- =====================================================================

-- いまログインしているメンバーのID(未ログインなら null)
create or replace function public.current_member_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select member_id from public.app_sessions where auth_uid = auth.uid();
$$;

-- いまログインしているメンバーが管理者か
create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    (select m.is_admin from public.members m where m.id = public.current_member_id()),
    false
  );
$$;


-- =====================================================================
--  トリガー
-- =====================================================================

-- 予定を更新したら updated_at を今の時刻に
create or replace function public.tg_availability_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists availability_updated_at on public.availability;
create trigger availability_updated_at
  before insert or update on public.availability
  for each row execute function public.tg_availability_updated_at();

-- 予定が 追加/変更/削除 されたら、その人の last_activity_at を更新(赤丸用)
-- ※ 削除も「更新」として赤丸を出すため、テーブル側で記録しておく
create or replace function public.tg_availability_activity()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  update public.members
     set last_activity_at = now()
   where id = coalesce(new.member_id, old.member_id);
  return null;
end;
$$;

drop trigger if exists availability_activity on public.availability;
create trigger availability_activity
  after insert or update or delete on public.availability
  for each row execute function public.tg_availability_activity();


-- =====================================================================
--  サーバー側関数(ログイン・PIN・管理者操作)
-- =====================================================================

-- ログイン画面の「名前リスト」用(PINなどは返さない)
create or replace function public.list_members_for_login()
returns table (id uuid, name text)
language sql stable security definer
set search_path = public
as $$
  select m.id, m.name from public.members m order by m.name;
$$;

-- 名前とPINを照合してログイン
--   成功: {"ok":true, "member":{...}}
--   失敗: {"ok":false, "error":"wrong_pin"|"locked"|"not_found"|"no_pin", ...}
-- ※ 失敗回数を確実に記録するため、例外ではなく結果を返す方式
create or replace function public.verify_pin(p_name text, p_pin text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  m public.members;
  v_attempts int;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'no_auth');
  end if;

  select * into m from public.members where name = p_name for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if m.locked_until is not null and m.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked',
      'minutes', ceil(extract(epoch from (m.locked_until - now())) / 60));
  end if;

  if m.pin_hash is null then
    return jsonb_build_object('ok', false, 'error', 'no_pin');
  end if;

  if p_pin is null or crypt(p_pin, m.pin_hash) <> m.pin_hash then
    v_attempts := m.failed_attempts + 1;
    if v_attempts >= 5 then
      update public.members
         set failed_attempts = 0, locked_until = now() + interval '15 minutes'
       where id = m.id;
      return jsonb_build_object('ok', false, 'error', 'locked', 'minutes', 15);
    end if;
    update public.members set failed_attempts = v_attempts where id = m.id;
    return jsonb_build_object('ok', false, 'error', 'wrong_pin', 'remaining', 5 - v_attempts);
  end if;

  -- 成功
  update public.members set failed_attempts = 0, locked_until = null where id = m.id;
  insert into public.app_sessions (auth_uid, member_id)
       values (auth.uid(), m.id)
  on conflict (auth_uid) do update set member_id = excluded.member_id, created_at = now();

  return jsonb_build_object('ok', true, 'member', jsonb_build_object(
    'id', m.id, 'name', m.name, 'is_admin', m.is_admin,
    'pin_change_prompted', m.pin_change_prompted));
end;
$$;

-- 自分のPINを変更
create or replace function public.change_pin(p_current text, p_new text)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_me uuid := public.current_member_id();
  v_hash text;
begin
  if v_me is null then raise exception 'ログインしていません'; end if;
  if p_new !~ '^[0-9]{4}$' then raise exception 'PINは4桁の数字にしてください'; end if;

  select pin_hash into v_hash from public.members where id = v_me;
  if v_hash is null or crypt(p_current, v_hash) <> v_hash then
    raise exception '今のPINが違います';
  end if;

  update public.members
     set pin_hash = crypt(p_new, gen_salt('bf')), pin_change_prompted = true
   where id = v_me;
end;
$$;

-- 初回の「PINを変えますか?」を表示済みにする(スキップ時)
create or replace function public.mark_pin_prompted()
returns void
language sql security definer
set search_path = public
as $$
  update public.members set pin_change_prompted = true where id = public.current_member_id();
$$;

-- 管理者: PINを設定/リセット
create or replace function public.admin_set_pin(p_member_id uuid, p_new text)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then raise exception '管理者だけができる操作です'; end if;
  if p_new !~ '^[0-9]{4}$' then raise exception 'PINは4桁の数字にしてください'; end if;

  update public.members
     set pin_hash = crypt(p_new, gen_salt('bf')),
         failed_attempts = 0, locked_until = null,
         pin_change_prompted = false
   where id = p_member_id;
  if not found then raise exception 'メンバーが見つかりません'; end if;
end;
$$;

-- 管理者: メンバーを追加(名前+初期PIN)
create or replace function public.admin_add_member(p_name text, p_pin text)
returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then raise exception '管理者だけができる操作です'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'PINは4桁の数字にしてください'; end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then raise exception '名前を入れてください'; end if;
  if exists (select 1 from public.members where name = trim(p_name)) then
    raise exception '同じ名前の人がすでにいます';
  end if;

  insert into public.members (name, pin_hash)
       values (trim(p_name), crypt(p_pin, gen_salt('bf')))
  returning id into v_id;

  -- 管理者は初期状態で全員をフォロー
  insert into public.follows (follower_id, followee_id)
  select a.id, v_id from public.members a where a.is_admin
  on conflict do nothing;

  return v_id;
end;
$$;

-- 管理者: メンバーを削除(その人の予定なども一緒に消えます)
create or replace function public.admin_delete_member(p_member_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception '管理者だけができる操作です'; end if;
  if p_member_id = public.current_member_id() then
    raise exception '自分自身は削除できません';
  end if;
  delete from public.members where id = p_member_id;
end;
$$;

-- 関数の実行権限(必要なものだけ許可)
revoke all on function public.current_member_id()             from public, anon;
revoke all on function public.is_admin()                      from public, anon;
revoke all on function public.list_members_for_login()        from public;
revoke all on function public.verify_pin(text, text)          from public, anon;
revoke all on function public.change_pin(text, text)          from public, anon;
revoke all on function public.mark_pin_prompted()             from public, anon;
revoke all on function public.admin_set_pin(uuid, text)       from public, anon;
revoke all on function public.admin_add_member(text, text)    from public, anon;
revoke all on function public.admin_delete_member(uuid)       from public, anon;

grant execute on function public.current_member_id()          to authenticated;
grant execute on function public.is_admin()                   to authenticated;
grant execute on function public.list_members_for_login()     to anon, authenticated;
grant execute on function public.verify_pin(text, text)       to authenticated;
grant execute on function public.change_pin(text, text)       to authenticated;
grant execute on function public.mark_pin_prompted()          to authenticated;
grant execute on function public.admin_set_pin(uuid, text)    to authenticated;
grant execute on function public.admin_add_member(text, text) to authenticated;
grant execute on function public.admin_delete_member(uuid)    to authenticated;


-- =====================================================================
--  RLS(Row Level Security)
-- =====================================================================

alter table public.members      enable row level security;
alter table public.app_sessions enable row level security;
alter table public.availability enable row level security;
alter table public.follows      enable row level security;
alter table public.last_seen    enable row level security;
alter table public.keepalive    enable row level security;

-- ---- members ----
-- PINの暗号やロック情報は見せない(列ごとに読める範囲を制限)
-- 追加・変更・削除は上の管理者用関数からのみ
revoke all on public.members from anon, authenticated;
grant select (id, name, is_admin, last_activity_at, created_at) on public.members to authenticated;

drop policy if exists members_select on public.members;
create policy members_select on public.members
  for select to authenticated
  using (public.current_member_id() is not null);

-- ---- app_sessions ----
-- 自分のログイン状態だけ見られる/消せる(ログアウト用)。作成は verify_pin のみ
revoke all on public.app_sessions from anon, authenticated;
grant select, delete on public.app_sessions to authenticated;

drop policy if exists app_sessions_select on public.app_sessions;
create policy app_sessions_select on public.app_sessions
  for select to authenticated
  using (auth_uid = auth.uid());

drop policy if exists app_sessions_delete on public.app_sessions;
create policy app_sessions_delete on public.app_sessions
  for delete to authenticated
  using (auth_uid = auth.uid());

-- ---- availability ----
-- 読む: ログイン済みなら全員分 / 書く: 自分の分だけ / 消す: 自分の分(管理者は誰の分でも)
revoke all on public.availability from anon;
grant select, insert, update, delete on public.availability to authenticated;

drop policy if exists availability_select on public.availability;
create policy availability_select on public.availability
  for select to authenticated
  using (public.current_member_id() is not null);

drop policy if exists availability_insert on public.availability;
create policy availability_insert on public.availability
  for insert to authenticated
  with check (member_id = public.current_member_id());

drop policy if exists availability_update on public.availability;
create policy availability_update on public.availability
  for update to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id());

drop policy if exists availability_delete on public.availability;
create policy availability_delete on public.availability
  for delete to authenticated
  using (member_id = public.current_member_id() or public.is_admin());

-- ---- follows ----
revoke all on public.follows from anon;
grant select, insert, delete on public.follows to authenticated;

drop policy if exists follows_own on public.follows;
create policy follows_own on public.follows
  for all to authenticated
  using (follower_id = public.current_member_id())
  with check (follower_id = public.current_member_id());

-- ---- last_seen ----
revoke all on public.last_seen from anon;
grant select, insert, update, delete on public.last_seen to authenticated;

drop policy if exists last_seen_own on public.last_seen;
create policy last_seen_own on public.last_seen
  for all to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id());

-- ---- keepalive ----
-- 自動ping(GitHub Actions)から読むだけ
revoke all on public.keepalive from anon, authenticated;
grant select on public.keepalive to anon, authenticated;

drop policy if exists keepalive_select on public.keepalive;
create policy keepalive_select on public.keepalive
  for select to anon, authenticated
  using (true);


-- =====================================================================
--  最初の管理者(Yama / PIN 0000)
--  ※ ログイン後すぐにPINを変更してください
-- =====================================================================
insert into public.members (name, pin_hash, is_admin)
values ('Yama', extensions.crypt('0000', extensions.gen_salt('bf')), true)
on conflict (name) do nothing;


-- 完了確認用: 下に「Yama」が1行出れば成功です
select name, is_admin, created_at from public.members;
