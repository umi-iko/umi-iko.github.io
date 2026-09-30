-- =====================================================================
--  サーフィン行こ  追加SQL その10: プッシュ通知
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  しくみ:
--   - 仲間が塗る/書き込むと「出来事」(notify_events)が記録される
--   - 1分ごとに Edge Function「notify」が呼ばれ、各自の通知設定に合う出来事だけを
--     その人の端末(push_subscriptions)に送る
--   - 通知設定: notify_settings(出し方など)/ notify_rules(何を通知するか)
-- =====================================================================

-- ============ 拡張(pg_cron: 定期実行 / pg_net: HTTP呼び出し) ============
do $$
begin
  begin create extension if not exists pg_net;  exception when others then raise notice 'pg_net: %', sqlerrm; end;
  begin create extension if not exists pg_cron; exception when others then raise notice 'pg_cron: %', sqlerrm; end;
end $$;


-- ============ テーブル ============

-- 通知を受け取る端末
create table if not exists public.push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references public.members(id) on delete cascade,
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  device       text,
  badge_count  int not null default 0,     -- アイコンの数字(アプリを開くと0に)
  failed       int not null default 0,
  created_at   timestamptz not null default now(),
  last_sent_at timestamptz
);

-- 通知の出し方
create table if not exists public.notify_settings (
  member_id   uuid primary key references public.members(id) on delete cascade,
  mode        text not null default 'quiet' check (mode in ('quiet','normal')),  -- 控えめ / しっかり
  trip_posts  boolean not null default true,   -- 掲示板の新着
  trip_events boolean not null default true,   -- 確定・募集・しおり
  updated_at  timestamptz not null default now()
);

-- 予定の通知ルール(複数作れる)
create table if not exists public.notify_rules (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references public.members(id) on delete cascade,
  color      text not null default 'blue'
             check (color in ('blue','green','orange','red','purple','yellow')),
  genres     text[] not null default '{sea,pool,abroad}',
  intents    text[] not null default '{go,if_someone}',
  days_ahead int check (days_ahead is null or days_ahead between 1 and 365),  -- null=期間の制限なし
  member_ids uuid[],                                                          -- null=見せてもらっている全員
  enabled    boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);

-- 出来事(送信待ち)
create table if not exists public.notify_events (
  id           bigint generated always as identity primary key,
  kind         text not null,
  actor_id     uuid,
  trip_id      uuid,
  genre        text,
  intent       text,
  date         date,
  target_id    uuid,
  payload      jsonb,
  created_at   timestamptz not null default now(),
  processed_at timestamptz
);
create index if not exists notify_events_pending_idx on public.notify_events (id) where processed_at is null;

-- ============ RLS ============
alter table public.push_subscriptions enable row level security;
alter table public.notify_settings    enable row level security;
alter table public.notify_rules       enable row level security;
alter table public.notify_events      enable row level security;

revoke all on public.push_subscriptions from anon, authenticated;
revoke all on public.notify_settings    from anon, authenticated;
revoke all on public.notify_rules       from anon, authenticated;
revoke all on public.notify_events      from anon, authenticated;   -- 直接は触れない(送信プログラムだけ)

grant select, delete on public.push_subscriptions to authenticated;
grant select, insert, update, delete on public.notify_settings to authenticated;
grant select, insert, update, delete on public.notify_rules    to authenticated;

drop policy if exists push_subs_own on public.push_subscriptions;
create policy push_subs_own on public.push_subscriptions
  for all to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id());

drop policy if exists notify_settings_own on public.notify_settings;
create policy notify_settings_own on public.notify_settings
  for all to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id());

drop policy if exists notify_rules_own on public.notify_rules;
create policy notify_rules_own on public.notify_rules
  for all to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id());


-- ============ 端末の登録・解除・バッジのリセット ============
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_device text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare v_me uuid := public.current_member_id();
begin
  if v_me is null then raise exception 'ログインしていません'; end if;
  insert into public.push_subscriptions (member_id, endpoint, p256dh, auth, device)
       values (v_me, p_endpoint, p_p256dh, p_auth, left(coalesce(p_device, ''), 120))
  on conflict (endpoint) do update
     set member_id = excluded.member_id, p256dh = excluded.p256dh, auth = excluded.auth,
         device = excluded.device, failed = 0;
  -- 初回は基本の設定とルールを用意
  insert into public.notify_settings (member_id) values (v_me) on conflict do nothing;
  if not exists (select 1 from public.notify_rules where member_id = v_me) then
    insert into public.notify_rules (member_id, color, genres, intents, days_ahead)
         values (v_me, 'blue', '{sea,pool,abroad}', '{go,if_someone}', 14);
  end if;
end;
$$;

create or replace function public.remove_push_subscription(p_endpoint text)
returns void
language sql security definer
set search_path = public
as $$
  delete from public.push_subscriptions
   where endpoint = p_endpoint and member_id = public.current_member_id();
$$;

-- アプリを開いたとき: この人の全端末のバッジを0に
create or replace function public.clear_badge()
returns void
language sql security definer
set search_path = public
as $$
  update public.push_subscriptions set badge_count = 0
   where member_id = public.current_member_id() and badge_count <> 0;
$$;

-- テスト通知(自分だけに届く)
create or replace function public.send_test_notification()
returns void
language sql security definer
set search_path = public
as $$
  insert into public.notify_events (kind, target_id) values ('test', public.current_member_id());
$$;

revoke all on function public.save_push_subscription(text, text, text, text) from public, anon;
revoke all on function public.remove_push_subscription(text)                 from public, anon;
revoke all on function public.clear_badge()                                  from public, anon;
revoke all on function public.send_test_notification()                       from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.remove_push_subscription(text)                 to authenticated;
grant execute on function public.clear_badge()                                  to authenticated;
grant execute on function public.send_test_notification()                       to authenticated;


-- ============ 出来事を記録するトリガー ============

-- 予定(海・プール・海外): 今日以降の「行く / 誰か行こう / ワンチャン」
create or replace function public.tg_notify_availability()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and old.intent = new.intent then return null; end if;   -- メモだけの変更は対象外
  if new.date < public.jst_today() then return null; end if;
  insert into public.notify_events (kind, actor_id, genre, intent, date)
       values ('avail', new.member_id, new.genre, new.intent, new.date);
  return null;
end;
$$;
drop trigger if exists notify_availability on public.availability;
create trigger notify_availability
  after insert or update on public.availability
  for each row execute function public.tg_notify_availability();

-- 掲示板の書き込み
create or replace function public.tg_notify_trip_post()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  insert into public.notify_events (kind, actor_id, trip_id, payload)
       values ('trip_post', new.member_id, new.trip_id, jsonb_build_object('body', left(new.body, 80)));
  return null;
end;
$$;
drop trigger if exists notify_trip_post on public.trip_posts;
create trigger notify_trip_post
  after insert on public.trip_posts
  for each row execute function public.tg_notify_trip_post();

-- トリップ: 確定 / しおり更新 / 募集開始
create or replace function public.tg_notify_trip()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if new.confirmed_start is not null and new.confirmed_start is distinct from old.confirmed_start then
    insert into public.notify_events (kind, actor_id, trip_id) values ('trip_confirm', new.created_by, new.id);
  end if;
  if new.notes is distinct from old.notes then
    insert into public.notify_events (kind, actor_id, trip_id) values ('trip_notes', new.notes_updated_by, new.id);
  end if;
  if new.recruit_open and not old.recruit_open then
    insert into public.notify_events (kind, actor_id, trip_id) values ('recruit_open', new.created_by, new.id);
  end if;
  return null;
end;
$$;
drop trigger if exists notify_trip on public.trips;
create trigger notify_trip
  after update on public.trips
  for each row execute function public.tg_notify_trip();

-- 募集: 回答(主催者へ) / 確定・キャンセル待ち(本人へ)
create or replace function public.tg_notify_invite()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_owner uuid;
begin
  select created_by into v_owner from public.trips where id = new.trip_id;
  if new.status is distinct from old.status and new.status <> 'invited' then
    insert into public.notify_events (kind, actor_id, trip_id, target_id, payload)
         values ('recruit_response', new.member_id, new.trip_id, v_owner, jsonb_build_object('status', new.status));
  end if;
  if new.result is distinct from old.result and new.result is not null then
    insert into public.notify_events (kind, actor_id, trip_id, target_id, payload)
         values ('recruit_result', v_owner, new.trip_id, new.member_id,
                 jsonb_build_object('result', new.result, 'order', new.waitlist_order));
  end if;
  return null;
end;
$$;
drop trigger if exists notify_invite on public.trip_invites;
create trigger notify_invite
  after update on public.trip_invites
  for each row execute function public.tg_notify_invite();


-- ============ 送信プログラムの合言葉(NOTIFY_SECRET)の置き場所 ============
-- GitHub に置いたコードには書かず、データベースの中(private.settings)にだけ入れます。
-- 値の登録は別途、SQL Editor で
--   insert into private.settings (key, value) values ('notify_secret', 'ここに合言葉')
--   on conflict (key) do update set value = excluded.value;
-- を実行します(手順は README「プッシュ通知」参照)。
create schema if not exists private;
create table if not exists private.settings (key text primary key, value text not null);
revoke all on schema private from public, anon, authenticated;
revoke all on private.settings from public, anon, authenticated;

-- ============ 1分ごとに送信プログラムを呼ぶ(pg_cron) ============
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

-- 完了確認
select 'OK' as result;
