/* サーフィン行こ Service Worker
   index.html は network-first(常に最新を取りに行き、オフライン時だけキャッシュ)。
   これでアプリ更新時に古い画面が残る問題を防ぎます。 */
const CACHE = 'surf-iko-v4';
const ASSETS = ['./index.html', './manifest.json', './icons/icon-192.png', './icons/icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  // Supabase等の外部アクセスはキャッシュしない
  if (url.origin !== location.origin) return;

  // ページ本体(ナビゲーション)と index.html は network-first
  if (e.request.mode === 'navigate' || url.pathname.endsWith('/index.html')) {
    e.respondWith(
      fetch(e.request)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put('./index.html', copy));
          return res;
        })
        .catch(() => caches.match('./index.html'))
    );
    return;
  }

  // 使い方の画像は「まず手元を出して、裏で更新」(次に開いたとき新しくなる)
  if (url.pathname.includes('/help/')) {
    e.respondWith(
      caches.match(e.request).then((hit) => {
        const net = fetch(e.request).then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(e.request, copy));
          return res;
        }).catch(() => hit);
        return hit || net;
      })
    );
    return;
  }

  // その他(アイコン等)は cache-first
  e.respondWith(
    caches.match(e.request).then((hit) => hit || fetch(e.request).then((res) => {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy));
      return res;
    }))
  );
});


/* ================= プッシュ通知 ================= */
self.addEventListener('push', (e) => {
  let data = {};
  try { data = e.data ? e.data.json() : {}; } catch (err) { data = { title: 'サーフィン行こ', body: e.data ? e.data.text() : '' }; }
  const quiet = !!data.quiet;
  const show = self.registration.showNotification(data.title || 'サーフィン行こ', {
    body: data.body || '',
    icon: './icons/icon-192.png',
    badge: './icons/icon-192.png',
    tag: data.tag || 'surf-iko',
    renotify: !quiet,           // 控えめ: 上書きしても音・振動なし
    silent: quiet,
    data: { url: data.url || './' },
  });
  // アイコンの数字(iOS 16.4+ / Android)
  const badge = (typeof data.badge === 'number' && 'setAppBadge' in self.navigator)
    ? self.navigator.setAppBadge(data.badge).catch(() => {}) : Promise.resolve();
  e.waitUntil(Promise.all([show, badge]));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) {
      if (c.url.startsWith(self.registration.scope) && 'focus' in c) {
        c.postMessage({ type: 'open', url });
        return c.focus();
      }
    }
    return self.clients.openWindow(url);
  }));
});

// 端末側で登録が更新されたときは、ページ側に再登録を頼む
self.addEventListener('pushsubscriptionchange', (e) => {
  e.waitUntil(self.clients.matchAll({ type: 'window' }).then((list) => {
    list.forEach((c) => c.postMessage({ type: 'resubscribe' }));
  }));
});
