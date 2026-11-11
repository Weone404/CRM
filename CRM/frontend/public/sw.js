// We One CRM service worker: phone notifications only. It does not cache pages, so updates show at once.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'We One CRM', {
    body: d.body || '',
    tag: d.tag || undefined,
    renotify: Boolean(d.tag),
    icon: '/icons/icon-192.png',
    badge: '/icons/badge-96.png',
    data: { url: d.url || '/#/amazon' },
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || '/#/amazon', self.location.origin).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if (new URL(w.url).origin !== self.location.origin) continue;
      await w.focus();
      w.postMessage({ type: 'open', url });
      return;
    }
    await self.clients.openWindow(url);
  })());
});
