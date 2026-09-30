-- =====================================================================
--  サーフィン行こ  追加SQL その3: ログインを「名前を入力」方式に
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  変更点:
--   - ログイン画面用の「名前一覧」を、ログイン前には取得できないようにする
--   - 名前は大文字・小文字や前後の空白を気にせず照合する(yama でも Yama でもOK)
--   - 「名前が違う」と「PINが違う」を区別せず同じ結果を返す
--     (外部の人が、ある名前が登録されているかを確かめられないように)
-- =====================================================================

-- 名前一覧の関数は使わなくなったので削除
drop function if exists public.list_members_for_login();

-- 名前とPINを照合してログイン
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

  select * into m from public.members
   where lower(name) = lower(trim(coalesce(p_name, '')))
   order by created_at
   limit 1
   for update;

  -- 名前が見つからない場合も、PIN違いと同じ結果を返す
  if not found then
    perform pg_sleep(0.3);   -- 応答時間の差で見分けられないように
    return jsonb_build_object('ok', false, 'error', 'wrong');
  end if;

  if m.locked_until is not null and m.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked',
      'minutes', ceil(extract(epoch from (m.locked_until - now())) / 60));
  end if;

  if m.pin_hash is null or p_pin is null or crypt(p_pin, m.pin_hash) <> m.pin_hash then
    v_attempts := m.failed_attempts + 1;
    if v_attempts >= 5 then
      update public.members
         set failed_attempts = 0, locked_until = now() + interval '15 minutes'
       where id = m.id;
      return jsonb_build_object('ok', false, 'error', 'locked', 'minutes', 15);
    end if;
    update public.members set failed_attempts = v_attempts where id = m.id;
    return jsonb_build_object('ok', false, 'error', 'wrong');
  end if;

  update public.members set failed_attempts = 0, locked_until = null where id = m.id;
  insert into public.app_sessions (auth_uid, member_id)
       values (auth.uid(), m.id)
  on conflict (auth_uid) do update set member_id = excluded.member_id, created_at = now();

  return jsonb_build_object('ok', true, 'member', jsonb_build_object(
    'id', m.id, 'name', m.name, 'is_admin', m.is_admin,
    'pin_change_prompted', m.pin_change_prompted));
end;
$$;

revoke all on function public.verify_pin(text, text) from public, anon;
grant execute on function public.verify_pin(text, text) to authenticated;

-- メンバー追加: 大文字・小文字違いの同名も「同じ名前」として止める
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
  if exists (select 1 from public.members where lower(name) = lower(trim(p_name))) then
    raise exception '同じ名前の人がすでにいます';
  end if;

  insert into public.members (name, pin_hash)
       values (trim(p_name), crypt(p_pin, gen_salt('bf')))
  returning id into v_id;

  insert into public.follows (follower_id, followee_id)
  select a.id, v_id from public.members a where a.is_admin
  on conflict do nothing;

  return v_id;
end;
$$;

revoke all on function public.admin_add_member(text, text) from public, anon;
grant execute on function public.admin_add_member(text, text) to authenticated;

-- 完了確認
select 'OK' as result
 where not exists (select 1 from pg_proc where proname = 'list_members_for_login');
