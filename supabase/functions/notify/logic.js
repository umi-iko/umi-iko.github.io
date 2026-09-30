/* 通知の組み立て(純粋な関数。Deno でも Node でも動く)
   入力: 出来事・端末・設定・ルール・見せる設定・メンバー・トリップ
   出力: 端末ごとに送る通知の一覧 */

export const GENRE_LABEL = { sea: '海', pool: 'プール', abroad: '海外' };
export const INTENT_LABEL = { go: '行く', if_someone: '誰か行こう', maybe: 'ワンチャン' };
export const COLOR_EMOJI = { blue: '🔵', green: '🟢', orange: '🟠', red: '🔴', purple: '🟣', yellow: '🟡' };
export const STATUS_LABEL = { go: '行く', positive: '前向きに検討', maybe: '様子見', no: '行けない' };

const DOW = ['日', '月', '火', '水', '木', '金', '土'];
export function fmtDate(s) {
  const [y, m, d] = s.split('-').map(Number);
  return `${m}/${d}(${DOW[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]})`;
}
export function addDays(s, n) {
  const [y, m, d] = s.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return t.toISOString().slice(0, 10);
}
export function toRanges(dates) {
  const sorted = [...new Set(dates)].sort();
  const out = []; let start = null, prev = null;
  for (const d of sorted) {
    if (start === null) { start = prev = d; continue; }
    if (d === addDays(prev, 1)) { prev = d; } else { out.push([start, prev]); start = prev = d; }
  }
  if (start !== null) out.push([start, prev]);
  return out;
}
export function rangeLabel([a, b]) {
  if (a === b) return fmtDate(a);
  const days = Math.round((Date.parse(b) - Date.parse(a)) / 86400000) + 1;
  return `${fmtDate(a)}〜${fmtDate(b)} ${days}日間`;
}

/**
 * @param ctx {
 *   events, subs, settings, rules, shares, members, tripMembers, trips, invites, today
 * }
 * @returns [{ sub, memberId, payload: { title, body, tag, url, quiet } }]
 */
export function buildNotifications(ctx) {
  const { events, subs, settings, rules, shares, members, tripMembers, trips, invites, today } = ctx;
  const name = (id) => (members.find((m) => m.id === id) || {}).name || '?';
  const setting = (id) => settings.find((s) => s.member_id === id) || { mode: 'quiet', trip_posts: true, trip_events: true };
  const trip = (id) => trips.find((t) => t.id === id);
  const membersOf = (tripId) => tripMembers.filter((r) => r.trip_id === tripId).map((r) => r.member_id);
  const shared = (owner, viewer) => shares.some((s) => s.owner_id === owner && s.viewer_id === viewer);
  const recipients = [...new Set(subs.map((s) => s.member_id))];

  // 受信者ごとの通知(まだ端末には割り当てない)
  const out = []; // { memberId, title, body, tag, url }
  const push = (memberId, n) => { if (recipients.includes(memberId)) out.push({ memberId, ...n }); };

  /* ---- 予定: (誰が・ジャンル・強さ)ごとにまとめる ---- */
  const availGroups = {};
  for (const e of events.filter((e) => e.kind === 'avail')) {
    const k = `${e.actor_id}|${e.genre}|${e.intent}`;
    (availGroups[k] = availGroups[k] || { actor: e.actor_id, genre: e.genre, intent: e.intent, dates: [] }).dates.push(e.date);
  }
  for (const r of recipients) {
    for (const rule of rules.filter((x) => x.member_id === r && x.enabled)) {
      const lines = [];
      const limit = rule.days_ahead ? addDays(today, rule.days_ahead) : null;
      for (const g of Object.values(availGroups)) {
        if (g.actor === r) continue;
        if (!shared(g.actor, r)) continue;                          // 見せてもらっている人だけ
        if (!(rule.genres || []).includes(g.genre)) continue;
        if (!(rule.intents || []).includes(g.intent)) continue;
        if (rule.member_ids && !rule.member_ids.includes(g.actor)) continue;
        const dates = g.dates.filter((d) => d >= today && (!limit || d <= limit));
        if (!dates.length) continue;
        lines.push(`${name(g.actor)}: ${GENRE_LABEL[g.genre] || g.genre}「${INTENT_LABEL[g.intent] || g.intent}」 ${toRanges(dates).map(rangeLabel).join('、')}`);
      }
      if (lines.length) {
        push(r, {
          title: `${COLOR_EMOJI[rule.color] || '🔵'} ${lines.length === 1 ? '予定の更新' : `予定の更新 ${lines.length}件`}`,
          body: lines.join('\n'),
          tag: `rule-${rule.id}`, url: './',
        });
      }
    }
  }

  /* ---- 掲示板 ---- */
  for (const e of events.filter((e) => e.kind === 'trip_post')) {
    const t = trip(e.trip_id); if (!t) continue;
    for (const m of membersOf(e.trip_id)) {
      if (m === e.actor_id || !setting(m).trip_posts) continue;
      push(m, { title: `💬 ${t.name}`, body: `${name(e.actor_id)}: ${(e.payload && e.payload.body) || ''}`, tag: `post-${t.id}`, url: `./?trip=${t.id}` });
    }
  }

  /* ---- トリップの連絡 ---- */
  for (const e of events.filter((e) => ['trip_confirm', 'trip_notes', 'recruit_open'].includes(e.kind))) {
    const t = trip(e.trip_id); if (!t) continue;
    const range = t.confirmed_start ? rangeLabel([t.confirmed_start, t.confirmed_end]) : '';
    if (e.kind === 'recruit_open') {
      for (const inv of invites.filter((i) => i.trip_id === t.id && !i.result)) {
        if (!setting(inv.member_id).trip_events) continue;
        push(inv.member_id, { title: `📣 ${t.name} 募集中`, body: `${range}。アプリで回答してね`, tag: `recruit-${t.id}`, url: `./?trip=${t.id}` });
      }
      continue;
    }
    for (const m of membersOf(t.id)) {
      if (m === e.actor_id || !setting(m).trip_events) continue;
      if (e.kind === 'trip_confirm') push(m, { title: `✅ ${t.name} 日程が決まりました`, body: range, tag: `trip-${t.id}`, url: `./?trip=${t.id}` });
      else push(m, { title: `📋 ${t.name} しおりが更新`, body: `${name(e.actor_id)} が更新しました`, tag: `notes-${t.id}`, url: `./?trip=${t.id}` });
    }
  }

  /* ---- 募集の回答(主催者へ)・結果(本人へ) ---- */
  for (const e of events.filter((e) => e.kind === 'recruit_response')) {
    const t = trip(e.trip_id); if (!t || !e.target_id || !setting(e.target_id).trip_events) continue;
    const st = e.payload && e.payload.status;
    push(e.target_id, { title: `📣 ${t.name}`, body: `${name(e.actor_id)} が「${STATUS_LABEL[st] || st}」と回答`, tag: `resp-${t.id}`, url: `./?trip=${t.id}` });
  }
  for (const e of events.filter((e) => e.kind === 'recruit_result')) {
    const t = trip(e.trip_id); if (!t || !e.target_id || !setting(e.target_id).trip_events) continue;
    const res = e.payload && e.payload.result;
    push(e.target_id, res === 'confirmed'
      ? { title: `🎉 ${t.name} 参加が確定しました`, body: rangeLabel([t.confirmed_start, t.confirmed_end]), tag: `result-${t.id}`, url: `./?trip=${t.id}` }
      : { title: `⏳ ${t.name} キャンセル待ち`, body: `${(e.payload && e.payload.order) || '?'}番目です`, tag: `result-${t.id}`, url: `./?trip=${t.id}` });
  }

  /* ---- テスト ---- */
  for (const e of events.filter((e) => e.kind === 'test')) {
    if (e.target_id) push(e.target_id, { title: '🌊 サーフィン行こ', body: '通知の設定ができました!', tag: 'test', url: './' });
  }

  /* ---- 端末に割り当て(控えめモードは1件に上書き) ---- */
  const result = [];
  for (const n of out) {
    const quiet = setting(n.memberId).mode !== 'normal';
    for (const sub of subs.filter((s) => s.member_id === n.memberId)) {
      result.push({ sub, memberId: n.memberId, payload: { title: n.title, body: n.body, url: n.url, quiet, tag: quiet ? 'surf-iko' : n.tag } });
    }
  }
  return result;
}
