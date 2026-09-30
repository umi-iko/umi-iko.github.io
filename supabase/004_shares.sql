-- =====================================================================
--  サーフィン行こ  追加SQL その4: 「見せる相手を自分で選ぶ」
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  変更点:
--   - 海・プール・海外の予定は、本人が「見せる」にチェックした相手にだけ見える
--     (データベース側で制限。アプリを改造されても見えない)
--   - 管理者も同じルール(本人が見せていない予定は見えない)
--   - 最初は誰にも見せない状態から始まる。各自が「仲間」タブで選ぶ
--   - トリップの調整帳は今まで通り(参加者どうしで見える)
-- =====================================================================

-- 誰が(owner)誰に(viewer)自分の予定を見せるか
create table if not exists public.shares (
  owner_id  uuid not null references public.members(id) on delete cascade,
  viewer_id uuid not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, viewer_id),
  check (owner_id <> viewer_id)
);

-- いまのメンバーが、その人の予定を見てよいか(本人 or 見せてもらっている)
create or replace function public.can_view(p_owner uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select p_owner = public.current_member_id()
      or exists (select 1 from public.shares
                  where owner_id = p_owner and viewer_id = public.current_member_id());
$$;

revoke all on function public.can_view(uuid) from public, anon;
grant execute on function public.can_view(uuid) to authenticated;

-- ---- shares の RLS ----
alter table public.shares enable row level security;
revoke all on public.shares from anon, authenticated;
grant select, insert, delete on public.shares to authenticated;

-- 見る: 自分が見せている相手 / 自分に見せてくれている人 の行だけ
drop policy if exists shares_select on public.shares;
create policy shares_select on public.shares
  for select to authenticated
  using (owner_id = public.current_member_id() or viewer_id = public.current_member_id());

-- 追加・削除: 自分の予定を見せる設定だけ
drop policy if exists shares_insert on public.shares;
create policy shares_insert on public.shares
  for insert to authenticated
  with check (owner_id = public.current_member_id());

drop policy if exists shares_delete on public.shares;
create policy shares_delete on public.shares
  for delete to authenticated
  using (owner_id = public.current_member_id());

-- 見せてもらったら、相手のカレンダーにも自動で「表示」を入れる(相手はあとで外せる)
create or replace function public.tg_share_autofollow()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.follows (follower_id, followee_id)
       values (new.viewer_id, new.owner_id)
  on conflict do nothing;
  return null;
end;
$$;

drop trigger if exists share_autofollow on public.shares;
create trigger share_autofollow
  after insert on public.shares
  for each row execute function public.tg_share_autofollow();

-- ---- availability: 読めるのは「見せてもらっている人」の分だけに変更 ----
drop policy if exists availability_select on public.availability;
create policy availability_select on public.availability
  for select to authenticated
  using (public.can_view(member_id));

-- ---- 最終更新日時も、見せてもらっている人の分だけ返す ----
-- (members.last_activity_at を直接読めないようにし、代わりにこの関数で返す)
revoke select on public.members from authenticated;
grant select (id, name, is_admin, created_at) on public.members to authenticated;

create or replace function public.visible_activity()
returns table (member_id uuid, last_activity_at timestamptz)
language sql stable security definer
set search_path = public
as $$
  select m.id, m.last_activity_at
    from public.members m
   where public.current_member_id() is not null
     and public.can_view(m.id);
$$;

revoke all on function public.visible_activity() from public, anon;
grant execute on function public.visible_activity() to authenticated;

-- 完了確認
select 'OK' as result
 where exists (select 1 from information_schema.tables where table_name = 'shares');
