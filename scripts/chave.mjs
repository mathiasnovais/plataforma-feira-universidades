/* ============================================================
   A service_role, num lugar só

   Todo script daqui precisa dela, e até agora cada um resolvia
   isso do seu jeito: uns liam a variável de ambiente, um tinha a
   chave escrita dentro. Na prática o dia a dia virou colar uma
   linha de `$env:` no PowerShell antes de cada comando — e essa
   linha foi a fonte de erro mais frequente do projeto. Ela é
   longa, some quando a janela fecha, e um Ctrl+V no lugar errado
   transforma o comando em outra coisa.

   Agora a ordem é:

     1. variável de ambiente SUPABASE_SERVICE_ROLE, se existir
        (útil em máquina compartilhada, onde nada fica em disco)
     2. o arquivo segredo-supabase.txt na raiz do projeto

   Com o arquivo no lugar, rodar um script é só `node scripts/x.mjs`.

   ATENÇÃO: segredo-supabase.txt ignora toda a segurança do banco.
   Não mande por e-mail, não suba para o Drive, não publique. Ele
   não vai para publicar/ — o preparar-deploy.mjs copia uma lista
   fixa de arquivos e este não está nela.

   Para trocar a chave: gere uma nova no Supabase (Settings > API
   Keys) e substitua o conteúdo do arquivo. Nada mais muda.
   ============================================================ */

import { readFileSync } from 'node:fs';

const ARQUIVO = 'segredo-supabase.txt';

function ler() {
  const doAmbiente = (process.env.SUPABASE_SERVICE_ROLE || '').trim();
  if (doAmbiente) return doAmbiente;

  try {
    const doArquivo = readFileSync(ARQUIVO, 'utf8').trim();
    if (doArquivo) return doArquivo;
  } catch (e) { /* não existe: cai no aviso abaixo */ }

  return null;
}

export const CHAVE = ler();

/* Chamado pelos scripts que não funcionam sem a chave. Explica o
   que fazer em vez de só dizer que falta. */
export function exigirChave() {
  if (CHAVE) return CHAVE;

  console.error('Não achei a service_role.');
  console.error('');
  console.error(`Crie o arquivo ${ARQUIVO} na pasta do projeto com a chave dentro.`);
  console.error('Ela está no Supabase: Settings > API Keys > aba "Legacy anon,');
  console.error('service_role API keys" > linha service_role > Reveal.');
  console.error('');
  console.error('O arquivo tem só a chave, numa linha, sem aspas e sem mais nada.');
  process.exit(1);
}

/* ============================================================
   A URL do projeto Supabase

   Mesma lógica da chave: primeiro a variável de ambiente
   SUPABASE_URL; se não houver, lê o config.js da raiz (o mesmo
   arquivo que as telas carregam). O config.js real não vai para
   o repositório; crie-o a partir de config.exemplo.js.
   ============================================================ */

const ARQUIVO_CONFIG = 'config.js';

function lerUrl() {
  const doAmbiente = (process.env.SUPABASE_URL || '').trim();
  if (doAmbiente) return doAmbiente;

  try {
    const texto = readFileSync(ARQUIVO_CONFIG, 'utf8');
    const achou = /SUPABASE_URL\s*:\s*['"]([^'"]+)['"]/.exec(texto);
    if (achou && !achou[1].includes('SEU-PROJETO')) return achou[1];
  } catch (e) { /* não existe: cai no aviso abaixo */ }

  return null;
}

export const URL_PROJETO = lerUrl();

export function exigirUrl() {
  if (URL_PROJETO) return URL_PROJETO;

  console.error('Não achei a URL do projeto Supabase.');
  console.error('');
  console.error(`Copie config.exemplo.js para ${ARQUIVO_CONFIG} e preencha SUPABASE_URL,`);
  console.error('ou defina a variável de ambiente SUPABASE_URL.');
  process.exit(1);
}
