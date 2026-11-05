/* ============================================================
   Service worker — só existe por causa do RF-08.
   O Wi-Fi do local é o maior risco do projeto. Sem cache do
   próprio app, um reload com a rede fora dá tela branca e o
   avaliador fica sem ferramenta no meio da fila.
   ============================================================ */

/* Trocar o nome força o descarte do cache antigo no activate. Foi
   trocado ao redesenhar a interface: sem isso, quem já tinha o app
   aberto continuaria com a tela velha até limpar o navegador. */
const CACHE = 'contatos-v5';

const ESTATICOS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './config.js',
  './logo-email.png',
  './icone-192.png',
  './icone-512.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js',
  'https://cdn.jsdelivr.net/npm/html5-qrcode@2.3.8/html5-qrcode.min.js'
];

self.addEventListener('install', evento => {
  evento.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // addAll é tudo-ou-nada: se um CDN falhar, a instalação inteira
    // cai. Aqui cada item é independente.
    await Promise.all(ESTATICOS.map(url =>
      cache.add(new Request(url, { mode: 'cors' })).catch(() => {})
    ));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', evento => {
  evento.waitUntil((async () => {
    const chaves = await caches.keys();
    await Promise.all(chaves.filter(c => c !== CACHE).map(c => caches.delete(c)));
    self.clients.claim();
  })());
});

self.addEventListener('fetch', evento => {
  const req = evento.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Nada de Supabase passa pelo cache: resposta de API com dado
  // pessoal de menor não fica gravada no disco do dispositivo.
  if (url.hostname.endsWith('.supabase.co')) return;

  // Navegação: rede primeiro (pega correção publicada no meio do
  // evento), cache como rede de segurança.
  if (req.mode === 'navigate') {
    /* Só o app do avaliador tem versão offline. As outras páginas do
       mesmo domínio — pesquisas, painel, credenciamento — passam
       direto: gravá-las sob './index.html' envenenava o cache e
       fazia o avaliador sem rede receber o formulário de satisfação
       no lugar do scanner. */
    const doApp = url.pathname === '/' || url.pathname.endsWith('/index.html');
    if (!doApp) return;

    evento.respondWith((async () => {
      try {
        const resposta = await fetch(req);
        const cache = await caches.open(CACHE);
        cache.put('./index.html', resposta.clone());
        return resposta;
      } catch (e) {
        return (await caches.match('./index.html')) || Response.error();
      }
    })());
    return;
  }

  // Bibliotecas e assets: cache primeiro, são versionados na URL.
  evento.respondWith((async () => {
    const emCache = await caches.match(req);
    if (emCache) return emCache;
    try {
      const resposta = await fetch(req);
      if (resposta && (resposta.ok || resposta.type === 'opaque')) {
        const cache = await caches.open(CACHE);
        cache.put(req, resposta.clone());
      }
      return resposta;
    } catch (e) {
      return Response.error();
    }
  })());
});
