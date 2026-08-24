// Service worker mínimo: deixa o console instalável e abre offline a casca
// (os dados vêm sempre da rede — dado de lead velho é pior que nenhum).
const CACHE = 'console-v1';
const CASCA = ['/', '/index.html', '/estilo.css', '/config.js', '/js/app.js', '/js/dados.js', '/js/graficos.js', '/icone.svg', '/manifest.webmanifest'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(CASCA)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (u.origin !== location.origin || e.request.method !== 'GET') return;
  e.respondWith(fetch(e.request).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); return r; }).catch(() => caches.match(e.request)));
});
