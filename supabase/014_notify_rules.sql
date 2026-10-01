-- =====================================================================
--  サーフィン行こ  追加SQL その14: 予定の通知の整理
--
--  使い方: Supabase の SQL Editor に全部貼り付けて「Run」。
--  何度実行しても壊れません。最後に「OK」と1行出れば成功です。
--
--  変更点:
--   - 同じ「人・ジャンル・日・強さ」の通知は一度だけ(送信済みの記録 notify_sent)
--   - 初めて通知をオンにしたときの基本ルールを「明後日まで」に
-- =====================================================================

create table if not exists public.notify_sent (
  actor_id uuid not null references public.members(id) on delete cascade,
  genre    text not null,
  date     date not null,
  intent   text not null,
  sent_at  timestamptz not null default now(),
  primary key (actor_id, genre, date, intent)
);
alter table public.notify_sent enable row level security;
revoke all on public.notify_sent from public, anon, authenticated;   -- 送信プログラム(service role)だけが読み書き

-- 送信済みのものは出来事を作らない(無駄な行を減らす)
create or replace function public.tg_notify_availability()
returns trigger
language plpgsql security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and old.intent = new.intent then return null; end if;   -- メモだけの変更は対象外
  if new.date < public.jst_today() then return null; end if;
  if exists (select 1 from public.notify_sent s
              where s.actor_id = new.member_id and s.genre = new.genre and s.date = new.date and s.intent = new.intent) then
    return null;
  end if;
  insert into public.notify_events (kind, actor_id, genre, intent, date)
       values ('avail', new.member_id, new.genre, new.intent, new.date);
  return null;
end;
$$;
drop trigger if exists notify_availability on public.availability;
create trigger notify_availability
  after insert or update on public.availability
  for each row execute function public.tg_notify_availability();

-- 初回の基本ルール: 海・プール・海外 / 行く・誰か行こう / 明後日まで
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
  insert into public.notify_settings (member_id) values (v_me) on conflict do nothing;
  if not exists (select 1 from public.notify_rules where member_id = v_me) then
    insert into public.notify_rules (member_id, color, genres, intents, days_ahead)
         values (v_me, 'blue', '{sea,pool,abroad}', '{go,if_someone}', 2);
  end if;
end;
$$;

select 'OK' as result;
