/* ============================================================
   Monta a pasta publicar/ com o que vai para o Cloudflare Pages.

   Existe para evitar um erro específico e caro: arrastar a pasta
   do projeto inteira para a hospedagem. Isso publicaria as
   migrations, os scripts, o workflow do n8n e — pior — a pasta
   saida/, com nome e token de todos os alunos.

   USO:
     node scripts/preparar-deploy.mjs
   ============================================================ */

import { copyFileSync, mkdirSync, readFileSync, existsSync, rmSync } from 'node:fs';

const ARQUIVOS = ['index.html', 'config.js', 'sw.js', 'manifest.webmanifest'];

/* A feira local publica três telas: o app do avaliador (index),
   o credenciamento e o painel ao vivo. As páginas da feira
   internacional (inscrição pública, painel de inscrições,
   palestras, pesquisas) estão em arquivo-internacional/ e voltam
   para esta lista se algum dia voltarem ao ar.

   logo-email.png não é usada por nenhuma página: existe para ter
   um endereço público que um e-mail possa carregar. */
const OPCIONAIS = ['logo-email.png', 'credenciamento.html', 'evento.html',
                   /* Ícone da aba e do atalho no celular, nos dois
                      tamanhos que o manifest declara. */
                   'icone-192.png', 'icone-512.png'];

/* ---- conferências antes de copiar ---- */

/* A URL e a chave anon ficam em config.js (copiado de
   config.exemplo.js). As telas carregam esse arquivo antes do
   supabase-js, por isso ele vai junto para publicar/. */
if (!existsSync('config.js')) {
  console.error('Falta o config.js. Copie config.exemplo.js para config.js e preencha.');
  process.exit(1);
}
const html = readFileSync('config.js', 'utf8');

if (html.includes('SUA_CHAVE_ANON') || html.includes('SEU-PROJETO.supabase.co')) {
  console.error('config.js ainda está com os valores de exemplo do Supabase.');
  process.exit(1);
}

/* Confere o papel dentro do JWT configurado, não a string
   "service_role" solta no arquivo — o próprio comentário do
   config.js cita esse nome e daria falso positivo. */
const chave = /SUPABASE_ANON_KEY\s*:\s*['"]([^'"]+)['"]/.exec(html)?.[1] || '';
const partes = chave.split('.');

if (partes.length === 3) {
  let papel = null;
  try {
    papel = JSON.parse(Buffer.from(partes[1], 'base64url').toString()).role;
  } catch (e) { /* não é JWT legível; segue para a checagem abaixo */ }

  if (papel && papel !== 'anon') {
    console.error(`PARE: a chave no config.js tem role "${papel}", não "anon".`);
    console.error('A service_role ignora toda a RLS e não pode ir para o navegador.');
    process.exit(1);
  }
  console.log('Chave conferida: role "anon".');
} else if (chave.startsWith('sb_secret_')) {
  console.error('PARE: config.js está com uma secret key. Use a publishable/anon.');
  process.exit(1);
}

const faltando = ARQUIVOS.filter(a => !existsSync(a));
if (faltando.length) {
  console.error('Arquivo(s) não encontrado(s):', faltando.join(', '));
  process.exit(1);
}

/* ---- monta a pasta ---- */

rmSync('publicar', { recursive: true, force: true });
mkdirSync('publicar', { recursive: true });

const copiados = [];
for (const arquivo of ARQUIVOS.concat(OPCIONAIS.filter(a => existsSync(a)))) {
  copyFileSync(arquivo, 'publicar/' + arquivo);
  copiados.push(arquivo);
}

console.log('publicar/ pronta com:');
for (const arquivo of copiados) console.log('  ' + arquivo);
console.log('\nArraste a pasta publicar/ para o Cloudflare Pages.');
console.log('Rode este comando de novo a cada alteração no index.html ou no config.js.');
