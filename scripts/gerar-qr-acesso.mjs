/* ============================================================
   Cartaz com o QR de acesso às telas que LEEM QR

   Os crachás dos alunos trazem um QR que aponta para o perfil
   deles. Este script faz o caminho inverso: um QR que, lido com a
   câmera do celular, abre a tela de LEITURA — o app do
   representante (index.html, raiz do site) e o credenciamento da
   mesa de entrada (credenciamento.html). Serve para colar no
   estande ou na mesa, para ninguém precisar digitar a URL.

   Sem npm install e sem banco. O QR é desenhado no navegador, em
   SVG, pela mesma biblioteca dos crachás (qrcode-generator, CDN),
   e o logo vai embutido para o arquivo abrir em qualquer máquina.

   USO (PowerShell):
     node scripts/gerar-qr-acesso.mjs                                  # usa a URL publicada
     node scripts/gerar-qr-acesso.mjs https://outro-dominio.com.br     # outra URL

   Saída: saida/qr-acesso.html — uma folha A4 por tela. Abra no
   navegador e imprima com Ctrl+P → Salvar como PDF, escala 100%,
   gráficos de fundo ligados.
   ============================================================ */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

/* URL do site publicado. Precisa ser a mesma que está dentro dos
   QRs dos crachás, senão o representante abre um app que não
   reconhece os crachás. */
const URL_PADRAO = 'https://feira-alfacem.pages.dev';
const URL_APP = (process.argv.slice(2).find(a => a.startsWith('http')) || URL_PADRAO).replace(/\/+$/, '');
const SAIDA = 'saida/qr-acesso.html';

/* Uma folha por tela. `caminho` vazio é a raiz do site (index.html). */
const TELAS = [
  {
    caminho: '',
    titulo: 'University Fair · Scanner app',
    quem: 'For university representatives',
    texto: 'Scan this code with your phone camera to open the app, sign in with your e-mail and start scanning student badges.',
    lingua: 'en'
  },
  {
    caminho: '/credenciamento.html',
    titulo: 'Credenciamento · Mesa de entrada',
    quem: 'Para a equipe da escola',
    texto: 'Aponte a câmera do celular para abrir a tela de credenciamento, entrar com o e-mail da escola e ler os crachás na entrada.',
    lingua: 'pt-BR'
  }
];

const escapar = t => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;');

const logo = 'data:image/png;base64,' + readFileSync('logo-email.png').toString('base64');

const folha = t => {
  const url = URL_APP + t.caminho;
  return `
  <section class="folha" lang="${t.lingua}">
    <img class="logo" src="${logo}" alt="">
    <h1>${escapar(t.titulo)}</h1>
    <p class="quem">${escapar(t.quem)}</p>
    <div class="qr" data-url="${escapar(url)}"></div>
    <p class="url">${escapar(url)}</p>
    <p class="texto">${escapar(t.texto)}</p>
  </section>`;
};

const html = `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>QR de acesso — telas de leitura</title>
<script src="https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js"><\/script>
<style>
  @page { size: A4 portrait; margin: 0; }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: #e9ecf1; color: #14181f;
    font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  .instrucoes {
    max-width: 190mm; margin: 16px auto; padding: 14px 20px;
    background: #fff; border: 1px solid #ccd3dc; border-radius: 10px;
    font-size: 13px; line-height: 1.5;
  }
  .instrucoes p { margin: 6px 0; }
  .folha {
    width: 210mm; height: 297mm; margin: 0 auto 16px; padding: 20mm;
    background: #fff; text-align: center;
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    break-after: page; page-break-after: always;
  }
  .logo { width: 60mm; height: auto; margin-bottom: 10mm; }
  h1 { font-size: 26pt; margin: 0 0 3mm; }
  .quem { font-size: 14pt; color: #5b6472; margin: 0 0 12mm; }
  /* 120mm de lado: lê de longe e de qualquer celular. O QR é
     SVG, então a borda sai firme no papel em qualquer escala. */
  .qr { width: 120mm; height: 120mm; }
  .qr svg { width: 100%; height: 100%; display: block; }
  .url { font-family: Consolas, Menlo, monospace; font-size: 13pt; margin: 10mm 0 6mm; word-break: break-all; }
  .texto { font-size: 13pt; line-height: 1.5; max-width: 140mm; margin: 0; color: #2b3340; }
  @media print {
    body { background: #fff; }
    .instrucoes { display: none; }
    .folha { margin: 0; }
  }
</style>
</head>
<body>

<div class="instrucoes">
  <p><b>QR de acesso: ${TELAS.length} folhas.</b>
  Imprima com <b>Ctrl+P</b> → Salvar como PDF, escala <b>100%</b>, margens <b>nenhuma</b> e
  <b>"Gráficos de fundo"</b> ligado (sem isso o logo não sai).</p>
  <p>Cada folha é um cartaz: o primeiro abre o app dos representantes (cole no estande),
  o segundo abre o credenciamento (cole na mesa de entrada). Os dois apontam para
  <b>${escapar(URL_APP)}</b>.</p>
</div>
${TELAS.map(folha).join('\n')}

<script>
  /* Nível Q de correção (25%): o cartaz vai levar dedo, fita e
     dobra, e um QR que só lê liso é um QR que não lê. */
  document.querySelectorAll('.qr').forEach(function (el) {
    var qr = qrcode(0, 'Q');
    qr.addData(el.dataset.url);
    qr.make();
    el.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 0, scalable: true });
  });
<\/script>
</body>
</html>
`;

mkdirSync('saida', { recursive: true });
writeFileSync(SAIDA, html);

console.log(`${TELAS.length} cartaz(es) em ${SAIDA}`);
for (const t of TELAS) console.log(`  ${t.titulo.padEnd(40)} ${URL_APP}${t.caminho}`);
console.log('\nAbra no navegador e imprima com Ctrl+P (escala 100%, sem margens, gráficos de fundo ligados).');
