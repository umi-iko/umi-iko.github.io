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
/* 今日・明日・明後日は言葉で、それ以降は日付で */
export function dayLabel(d, today) {
  if (d === today) return '今日';
  if (d === addDays(today, 1)) return '明日';
  if (d === addDays(today, 2)) return '明後日';
  return fmtDate(d);
}
export function datesLabel(dates, today) {
  return toRanges(dates).map(([a, b]) => a === b ? dayLabel(a, today) : `${dayLabel(a, today)}〜${dayLabel(b, today)}`).join('・');
}
/* 1人分の予定(複数の日・ジャンル・強さ)を1つの言い回しにする
   - ジャンルが1つ・強さも1つ: 行く→「海に行くよー / プール行くよー / 海外行くよー」、誰か行こう→「海 誰か行こう」、ワンチャン→「海 ワンチャン」
   - ジャンルが1つ・強さが混在: 「海に行ったりするよ / プール行ったりするよ」
   - ジャンルが混在: 「○○とか行こー」。○○は「誰か行こう」が入っているジャンル(複数なら早い日)、無ければ一番早い日のジャンル */
export function intentPhrase(genre, intent) {
  const g = GENRE_LABEL[genre] || genre;
  if (intent === 'go') return genre === 'sea' ? '海に行くよー' : `${g}行くよー`;
  return `${g} ${INTENT_LABEL[intent] || intent}`;
}
export function groupPhrase(items) {
  const byDate = [...items].sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : 0);
  const genres = [...new Set(byDate.map((i) => i.genre))];
  const intents = [...new Set(byDate.map((i) => i.intent))];
  if (genres.length > 1) {
    const pick = byDate.find((i) => i.intent === 'if_someone') || byDate[0];
    return `${GENRE_LABEL[pick.genre] || pick.genre}とか行こー`;
  }
  const g = genres[0];
  if (intents.length > 1) return g === 'sea' ? '海に行ったりするよ' : `${GENRE_LABEL[g] || g}行ったりするよ`;
  return intentPhrase(g, intents[0]);
}
/* 予定の出来事のうち「まだ送っていない」「いまも予定が残っている」ものだけを残す。
   current: いまの availability 行 / alreadySent: 送信済みキー(actor|genre|date|intent) */
export const availKey = (e) => `${e.actor_id || e.member_id}|${e.genre}|${e.date}|${e.intent}`;
export function liveAvailEvents(events, current, alreadySent) {
  const live = new Set((current || []).map(availKey));
  const sent = new Set(alreadySent || []);
  const seen = new Set();
  return events.filter((e) => {
    if (e.kind !== 'avail') return false;
    const k = availKey(e);
    if (sent.has(k) || seen.has(k)) return false;
    if (current && !live.has(k)) return false;   // もう消されている(誤タッチなど)
    seen.add(k); return true;
  });
}
export function rangeLabel([a, b]) {
  if (!a) return '';
  if (!b || a === b) return fmtDate(a);
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
  const { events, subs, settings, rules, shares, members, tripMembers, trips, invites, today, current, alreadySent } = ctx;
  const name = (id) => (members.find((m) => m.id === id) || {}).name || '?';
  const setting = (id) => settings.find((s) => s.member_id === id) || { mode: 'quiet', trip_posts: true, trip_events: true };
  const trip = (id) => trips.find((t) => t.id === id);
  const membersOf = (tripId) => tripMembers.filter((r) => r.trip_id === tripId).map((r) => r.member_id);
  const shared = (owner, viewer) => shares.some((s) => s.owner_id === owner && s.viewer_id === viewer);
  const recipients = [...new Set(subs.map((s) => s.member_id))];

  // 受信者ごとの通知(まだ端末には割り当てない)
  const out = []; // { memberId, title, body, tag, url }
  const push = (memberId, n) => { if (recipients.includes(memberId)) out.push({ memberId, ...n }); };

  /* ---- 予定: 人ごとに1行にまとめる(ジャンル・強さが混ざれば言い回しで吸収) ---- */
  const availEvents = liveAvailEvents(events, current, alreadySent);
  for (const r of recipients) {
    for (const rule of rules.filter((x) => x.member_id === r && x.enabled)) {
      const lines = [];
      const limit = rule.days_ahead ? addDays(today, rule.days_ahead) : null;
      const perActor = {};
      for (const e of availEvents) {
        if (e.actor_id === r) continue;
        if (!shared(e.actor_id, r)) continue;                        // 見せてもらっている人だけ
        if (!(rule.genres || []).includes(e.genre)) continue;
        if (!(rule.intents || []).includes(e.intent)) continue;
        if (rule.member_ids && !rule.member_ids.includes(e.actor_id)) continue;
        if (e.date < today || (limit && e.date > limit)) continue;
        (perActor[e.actor_id] = perActor[e.actor_id] || []).push({ genre: e.genre, intent: e.intent, date: e.date });
      }
      for (const [actor, items] of Object.entries(perActor)) {
        lines.push(`${name(actor)} ${datesLabel(items.map((i) => i.date), today)} ${groupPhrase(items)}`);
      }
      if (lines.length === 1) {
        push(r, { title: `${COLOR_EMOJI[rule.color] || '🔵'} ${lines[0]}`, body: '', tag: `rule-${rule.id}`, url: './' });
      } else if (lines.length > 1) {
        push(r, { title: `${COLOR_EMOJI[rule.color] || '🔵'} 予定の更新 ${lines.length}件`, body: lines.join('\n'), tag: `rule-${rule.id}`, url: './' });
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
      for (const inv of invites.filter((i) => i.trip_id === t.id && !i.result && (!e.target_id || i.member_id === e.target_id))) {
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
