// サーフィン行こ: プッシュ通知の送信(Supabase Edge Function)
// 1分ごとに pg_cron から呼ばれ、たまった「出来事」を各自の設定に合わせて端末へ送る。
// 必要な環境変数(GitHub Actions から自動で設定):
//   VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / NOTIFY_SECRET
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY は Supabase が自動で用意する
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3";
import { buildNotifications, liveAvailEvents, availKey } from "./logic.js";

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });

function jstToday(): string {
  return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("NOTIFY_SECRET") || "";
  if (!secret || req.headers.get("x-notify-secret") !== secret) return json({ error: "forbidden" }, 403);

  const pub = Deno.env.get("VAPID_PUBLIC_KEY") || "";
  const priv = Deno.env.get("VAPID_PRIVATE_KEY") || "";
  if (!pub || !priv) return json({ error: "VAPID keys not set" }, 500);
  webpush.setVapidDetails("https://umi-iko.github.io/", pub, priv);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // 1. 未処理の出来事を取り出し、先に「処理済み」にする(二重送信を防ぐ)
  // 予定(avail)は塗ってから5分待つ(塗り足しをまとめる・誤タッチで消した分は送らない)。それ以外はすぐ
  const graceIso = new Date(Date.now() - 5 * 60 * 1000).toISOString();
  const { data: events, error: e1 } = await sb.from("notify_events")
    .select("*").is("processed_at", null).or(`kind.neq.avail,created_at.lte.${graceIso}`).order("id").limit(500);
  if (e1) return json({ error: e1.message }, 500);
  if (!events || events.length === 0) {
    // ついでに古い出来事を掃除
    await sb.from("notify_events").delete().lt("created_at", new Date(Date.now() - 7 * 86400 * 1000).toISOString());
    return json({ sent: 0 });
  }
  await sb.from("notify_events").update({ processed_at: new Date().toISOString() }).in("id", events.map((e) => e.id));

  // 2. 通知先の情報を読む
  const [subs, settings, rules, shares, members, tripMembers, trips, invites] = await Promise.all([
    sb.from("push_subscriptions").select("*"),
    sb.from("notify_settings").select("*"),
    sb.from("notify_rules").select("*"),
    sb.from("shares").select("owner_id,viewer_id"),
    sb.from("members").select("id,name"),
    sb.from("trip_members").select("trip_id,member_id"),
    sb.from("trips").select("id,name,created_by,confirmed_start,confirmed_end"),
    sb.from("trip_invites").select("trip_id,member_id,result"),
  ].map((p) => p.then((r) => r.data || [])));

  // 2b. 予定の出来事: いまも残っているか・送信済みでないかを調べる
  const availEvents = events.filter((e) => e.kind === "avail");
  let current: any[] = [], alreadySent: string[] = [];
  if (availEvents.length) {
    const actors = [...new Set(availEvents.map((e) => e.actor_id))];
    const dates = [...new Set(availEvents.map((e) => e.date))];
    const [{ data: cur }, { data: sentRows }] = await Promise.all([
      sb.from("availability").select("member_id,genre,date,intent").in("member_id", actors).in("date", dates),
      sb.from("notify_sent").select("actor_id,genre,date,intent").in("actor_id", actors).in("date", dates),
    ]);
    current = cur || [];
    alreadySent = (sentRows || []).map(availKey);
  }

  // 3. 送る内容を組み立てる
  let plan: any[] = [];
  try {
    plan = buildNotifications({
      events, subs, settings, rules, shares, members, tripMembers, trips, invites, today: jstToday(), current, alreadySent,
    });
  } catch (err) {
    console.error("buildNotifications failed", err);
    return json({ error: String(err), events: events.length }, 500);
  }

  // 3b. 今回扱った予定は「送信済み」として記録(同じ人・ジャンル・日・強さは二度と送らない)
  const liveNow = liveAvailEvents(events, current, alreadySent);
  if (liveNow.length) {
    await sb.from("notify_sent").upsert(
      liveNow.map((e) => ({ actor_id: e.actor_id, genre: e.genre, date: e.date, intent: e.intent })),
      { onConflict: "actor_id,genre,date,intent", ignoreDuplicates: true });
  }

  // 4. 端末ごとに送る(バッジは端末ごとに加算)
  const badge: Record<string, number> = {};
  for (const s of subs) badge[s.id] = s.badge_count || 0;
  let sent = 0, removed = 0, failed = 0;
  for (const item of plan) {
    const sub = item.sub;
    badge[sub.id] = (badge[sub.id] || 0) + 1;
    const payload = JSON.stringify({ ...item.payload, badge: badge[sub.id] });
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        payload,
        { TTL: 6 * 3600, urgency: item.payload.quiet ? "low" : "normal" },
      );
      sent++;
    } catch (err) {
      const code = (err as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {              // 端末側で通知を切った → 登録を消す
        await sb.from("push_subscriptions").delete().eq("id", sub.id);
        delete badge[sub.id]; removed++;
      } else {
        failed++;
        await sb.from("push_subscriptions").update({ failed: (sub.failed || 0) + 1 }).eq("id", sub.id);
      }
    }
  }
  for (const [id, n] of Object.entries(badge)) {
    const before = subs.find((s) => s.id === id);
    if (before && before.badge_count !== n) {
      await sb.from("push_subscriptions").update({ badge_count: n, last_sent_at: new Date().toISOString() }).eq("id", id);
    }
  }
  return json({ events: events.length, planned: plan.length, sent, removed, failed });
});
