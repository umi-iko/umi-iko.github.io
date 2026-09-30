-- =====================================================================
--  サーフィン行こ  追加SQL その5: PINを6桁に
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  変更点:
--   - 新しく設定するPIN(本人の変更・管理者の追加/リセット)は6桁の数字だけ
--   - すでに4桁のPINの人も、そのままログインはできる。
--     ログイン時に needs_upgrade=true を返し、アプリが6桁への変更を求める
-- =====================================================================

-- ログイン(03 の内容 + needs_upgrade)
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

  if not found then
    perform pg_sleep(0.3);
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
    'pin_change_prompted', m.pin_change_prompted,
    'needs_upgrade', char_length(p_pin) < 6));
end;
$$;

revoke all on function public.verify_pin(text, text) from public, anon;
grant execute on function public.verify_pin(text, text) to authenticated;

-- 本人のPIN変更(新しいPINは6桁。今のPINは4桁でも6桁でも可)
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
  if p_new !~ '^[0-9]{6}$' then raise exception 'PINは6桁の数字にしてください'; end if;

  select pin_hash into v_hash from public.members where id = v_me;
  if v_hash is null or crypt(p_current, v_hash) <> v_hash then
    raise exception '今のPINが違います';
  end if;

  update public.members
     set pin_hash = crypt(p_new, gen_salt('bf')), pin_change_prompted = true
   where id = v_me;
end;
$$;

-- 管理者: PINを設定/リセット(6桁)
create or replace function public.admin_set_pin(p_member_id uuid, p_new text)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then raise exception '管理者だけができる操作です'; end if;
  if p_new !~ '^[0-9]{6}$' then raise exception 'PINは6桁の数字にしてください'; end if;

  update public.members
     set pin_hash = crypt(p_new, gen_salt('bf')),
         failed_attempts = 0, locked_until = null,
         pin_change_prompted = false
   where id = p_member_id;
  if not found then raise exception 'メンバーが見つかりません'; end if;
end;
$$;

-- 管理者: メンバー追加(初期PINは6桁)
create or replace function public.admin_add_member(p_name text, p_pin text)
returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then raise exception '管理者だけができる操作です'; end if;
  if p_pin !~ '^[0-9]{6}$' then raise exception 'PINは6桁の数字にしてください'; end if;
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

revoke all on function public.change_pin(text, text)       from public, anon;
revoke all on function public.admin_set_pin(uuid, text)    from public, anon;
revoke all on function public.admin_add_member(text, text) from public, anon;
grant execute on function public.change_pin(text, text)       to authenticated;
grant execute on function public.admin_set_pin(uuid, text)    to authenticated;
grant execute on function public.admin_add_member(text, text) to authenticated;

-- 完了確認
select 'OK' as result;
