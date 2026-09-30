-- =====================================================================
--  サーフィン行こ  追加SQL その12: 総点検で見つかった不具合の修正
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  直したこと:
--   1. ボートトリップで「参加者を保存」を押すと、募集で確定した人まで外れてしまっていた
--   2. 「確定・キャンセル待ちを保存」のたびに、決まっていた人にも同じ通知がもう一度届いていた
--   3. 確定を取り消しても募集が開いたままで、声をかけた人の画面が壊れていた
--   4. 募集を開いたあとに追加で声をかけた人に「募集中」の通知が届かなかった
--   5. 送信プログラムの合言葉(NOTIFY_SECRET)を、コードではなくデータベースの中に置く
-- =====================================================================

-- 1. 参加者の入れ替えは「コアメンバー」だけを対象にする(募集で確定した joined は触らない)
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
     and role = 'core'
     and member_id <> v_owner
     and not (member_id = any(coalesce(p_member_ids, '{}')));

  insert into public.trip_members (trip_id, member_id, role)
  select p_trip, m.id, 'core' from public.members m
   where m.id = v_owner or m.id = any(coalesce(p_member_ids, '{}'))
  on conflict (trip_id, member_id) do nothing;
end;
$$;

-- 2. 確定・キャンセル待ちの保存は「変わった人だけ」更新する(通知の二重送りを防ぐ)
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

  -- 外れる人だけ白紙に戻す
  update public.trip_invites set result = null, waitlist_order = null
   where trip_id = p_trip and result is not null
     and not (member_id = any(coalesce(p_confirmed, '{}')))
     and not (member_id = any(coalesce(p_waitlist, '{}')));
  -- 新しく確定になる人だけ
  update public.trip_invites set result = 'confirmed', waitlist_order = null
   where trip_id = p_trip and member_id = any(coalesce(p_confirmed, '{}'))
     and result is distinct from 'confirmed';
  -- キャンセル待ちは順番が変わった人だけ
  foreach v_id in array coalesce(p_waitlist, '{}') loop
    i := i + 1;
    update public.trip_invites set result = 'waitlist', waitlist_order = i
     where trip_id = p_trip and member_id = v_id
       and (result is distinct from 'waitlist' or waitlist_order is distinct from i);
  end loop;

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

-- 3. 確定の取り消し = 募集も閉じる
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
     set confirmed_start = null, confirmed_end = null, confirmed_at = null, recruit_open = false
   where id = p_trip;
end;
$$;

-- 4. 募集が開いている最中に追加で声をかけた人へ「募集中」を知らせる(その人だけ)
create or replace function public.tg_notify_invite_insert()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_owner uuid; v_open boolean;
begin
  select created_by, recruit_open into v_owner, v_open from public.trips where id = new.trip_id;
  if v_open then
    insert into public.notify_events (kind, actor_id, trip_id, target_id)
         values ('recruit_open', v_owner, new.trip_id, new.member_id);
  end if;
  return null;
end;
$$;
drop trigger if exists notify_invite_insert on public.trip_invites;
create trigger notify_invite_insert
  after insert on public.trip_invites
  for each row execute function public.tg_notify_invite_insert();

-- 5. 合言葉の置き場所(値そのものは別途1行のSQLで入れる。README参照)
create schema if not exists private;
create table if not exists private.settings (key text primary key, value text not null);
revoke all on schema private from public, anon, authenticated;
revoke all on private.settings from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('surf-iko-notify'); exception when others then null; end;
    perform cron.schedule('surf-iko-notify', '* * * * *', $cron$
      select net.http_post(
        url     := 'https://fxdqfbryqzfuuhabkpto.supabase.co/functions/v1/notify',
        headers := jsonb_build_object('Content-Type', 'application/json',
                     'x-notify-secret', coalesce((select value from private.settings where key = 'notify_secret'), '')),
        body    := '{}'::jsonb)
    $cron$);
  else
    raise notice 'pg_cron が使えないため、定期実行の予約はスキップしました';
  end if;
end $$;

select 'OK' as result;
