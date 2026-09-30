-- =====================================================================
--  サーフィン行こ  追加SQL その6: 招待コードで自分で登録
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  しくみ:
--   - 管理者が「招待コード」を決める(アプリの管理者メニューから)
--   - 招待コードを知っている人は、自分で名前と6桁PINを決めて登録できる
--   - 招待コードは管理者しか見られない。止める(無効にする)こともできる
--   - 当てずっぽうで何度も試されないよう、間違いが続くと一時的に受付停止
-- =====================================================================

-- 招待コード(1行だけ使う)
create table if not exists public.invite_settings (
  id         int primary key default 1 check (id = 1),
  code       text,                          -- null = 招待停止中
  updated_at timestamptz not null default now()
);
insert into public.invite_settings (id) values (1) on conflict (id) do nothing;

-- 間違った招待コードの記録(総当たり対策)
create table if not exists public.invite_failures (
  id bigint generated always as identity primary key,
  at timestamptz not null default now()
);

-- どちらのテーブルも直接は読み書きさせない(下の関数からのみ)
alter table public.invite_settings enable row level security;
alter table public.invite_failures enable row level security;
revoke all on public.invite_settings from anon, authenticated;
revoke all on public.invite_failures from anon, authenticated;


-- 管理者: 今の招待コードを見る
create or replace function public.admin_get_invite()
returns text
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception '管理者だけができる操作です'; end if;
  return (select code from public.invite_settings where id = 1);
end;
$$;

-- 管理者: 招待コードを設定する(null で停止)
create or replace function public.admin_set_invite(p_code text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v text := nullif(trim(coalesce(p_code, '')), '');
begin
  if not public.is_admin() then raise exception '管理者だけができる操作です'; end if;
  if v is not null and (char_length(v) < 6 or char_length(v) > 30) then
    raise exception '招待コードは6〜30文字にしてください';
  end if;
  if v is not null and v !~ '^[A-Za-z0-9-]+$' then
    raise exception '招待コードは英数字とハイフンだけにしてください';
  end if;
  update public.invite_settings set code = v, updated_at = now() where id = 1;
  delete from public.invite_failures;   -- 受付停止も解除
end;
$$;

-- 招待コードで自分を登録(そのままログイン状態になる)
--   成功: {"ok":true, "member":{...}}
--   失敗: {"ok":false, "error":"bad_code"|"busy"|"name_taken"|"bad_name"|"bad_pin"|"no_auth"}
create or replace function public.register_with_invite(p_code text, p_name text, p_pin text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_code text;
  v_name text := trim(coalesce(p_name, ''));
  v_id   uuid;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'no_auth');
  end if;

  -- 直近10分で間違いが20回を超えたら、しばらく受付停止
  if (select count(*) from public.invite_failures where at > now() - interval '10 minutes') >= 20 then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;

  select code into v_code from public.invite_settings where id = 1;
  if v_code is null or lower(trim(coalesce(p_code, ''))) <> lower(v_code) then
    insert into public.invite_failures default values;
    delete from public.invite_failures where at < now() - interval '1 day';
    perform pg_sleep(0.5);
    return jsonb_build_object('ok', false, 'error', 'bad_code');
  end if;

  if char_length(v_name) < 1 or char_length(v_name) > 20 then
    return jsonb_build_object('ok', false, 'error', 'bad_name');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{6}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_pin');
  end if;
  if exists (select 1 from public.members where lower(name) = lower(v_name)) then
    return jsonb_build_object('ok', false, 'error', 'name_taken');
  end if;

  insert into public.members (name, pin_hash, pin_change_prompted)
       values (v_name, crypt(p_pin, gen_salt('bf')), true)   -- 自分で決めたPINなので変更の案内は不要
  returning id into v_id;

  -- 管理者は初期状態で全員を「表示」
  insert into public.follows (follower_id, followee_id)
  select a.id, v_id from public.members a where a.is_admin
  on conflict do nothing;

  -- そのままログイン
  insert into public.app_sessions (auth_uid, member_id)
       values (auth.uid(), v_id)
  on conflict (auth_uid) do update set member_id = excluded.member_id, created_at = now();

  return jsonb_build_object('ok', true, 'member', jsonb_build_object(
    'id', v_id, 'name', v_name, 'is_admin', false));
end;
$$;

revoke all on function public.admin_get_invite()                        from public, anon;
revoke all on function public.admin_set_invite(text)                    from public, anon;
revoke all on function public.register_with_invite(text, text, text)    from public, anon;
grant execute on function public.admin_get_invite()                     to authenticated;
grant execute on function public.admin_set_invite(text)                 to authenticated;
grant execute on function public.register_with_invite(text, text, text) to authenticated;

-- 完了確認
select 'OK' as result;
