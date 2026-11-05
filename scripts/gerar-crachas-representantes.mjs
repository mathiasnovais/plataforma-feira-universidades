/* ============================================================
   Crachás dos representantes (universidades, agências, organização)

   O representante não está na tabela de alunos: ele não é
   escaneado, ele escaneia. Por isso o crachá dele não tem QR nem
   código — só nome, instituição e o que ele é. No lugar do QR vai
   o logo da Rede.

   Mesmo papel e mesma medida dos crachás dos alunos (80 x 40mm,
   2 x 7 por A4), para a gráfica cortar tudo igual.

   Sem npm install e sem banco: a lista é um CSV na raiz, com uma
   linha por pessoa.

   USO (PowerShell):
     node scripts/gerar-crachas-representantes.mjs                      # lê representantes.csv
     node scripts/gerar-crachas-representantes.mjs outra-lista.csv
     node scripts/gerar-crachas-representantes.mjs equipe.csv --saida=saida/crachas-equipe.html

   FORMATO DO CSV (primeira linha é cabeçalho; e-mail é opcional e
   não vai para o papel — fica só para cruzar com as contas):
     nome,email,organizacao,tipo
     Ana Souza,ana@uni.edu,Universidade Tal,universidade

   `tipo` vira a etiqueta impressa, em inglês porque é o idioma
   desse público (a mesma decisão do app deles):
     universidade      -> University representative
     agencia nacional  -> National agency
     organizacao       -> Organization
   Qualquer outro texto sai como está.

   Saída: saida/crachas-representantes.html. Abra no navegador e
   imprima com Ctrl+P → Salvar como PDF, escala 100%, gráficos de
   fundo ligados.
   ============================================================ */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const ARQUIVO = process.argv.slice(2).find(a => !a.startsWith('--')) || 'representantes.csv';
/* --saida=outro.html grava em outro arquivo, para uma lista avulsa
   (equipe, produção) não sobrescrever o dos representantes. */
const SAIDA = (process.argv.slice(2).find(a => a.startsWith("--saida=")) || "").slice(8)
  || "saida/crachas-representantes.html";

/* Parser de CSV mínimo: vírgula, campo entre aspas com vírgula dentro. */
function lerCsv(texto) {
  const linhas = texto.replace(/^﻿/, '').replace(/\r\n?/g, '\n').split('\n').filter(l => l.trim());
  if (!linhas.length) return [];
  const colunas = linhas.shift().split(',').map(c => c.trim().toLowerCase());
  return linhas.map(linha => {
    const campos = [];
    let atual = '', aspas = false;
    for (let i = 0; i < linha.length; i++) {
      const ch = linha[i];
      if (ch === '"') {
        if (aspas && linha[i + 1] === '"') { atual += '"'; i++; }
        else aspas = !aspas;
      } else if (ch === ',' && !aspas) { campos.push(atual.trim()); atual = ''; }
      else atual += ch;
    }
    campos.push(atual.trim());
    const obj = {};
    colunas.forEach((c, i) => { obj[c] = campos[i] || ''; });
    return obj;
  });
}

const normalizar = t => String(t || '').toLowerCase()
  .normalize('NFD').replace(/\p{M}/gu, '').replace(/[^a-z]/g, '');

const ETIQUETAS = {
  universidade: 'University representative',
  agencianacional: 'National agency',
  organizacao: 'Organization'
};
const etiqueta = tipo => ETIQUETAS[normalizar(tipo)] || tipo || 'Representative';

const escapar = t => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;');

/* ---- lista ---- */
let pessoas;
try {
  pessoas = lerCsv(readFileSync(ARQUIVO, 'utf8'));
} catch (e) {
  console.error(`Não consegui ler ${ARQUIVO}: ${e.message}`);
  process.exit(1);
}
const semNome = pessoas.filter(p => !p.nome);
pessoas = pessoas.filter(p => p.nome);
if (!pessoas.length) {
  console.error(`${ARQUIVO} não tem nenhuma linha com nome.`);
  process.exit(1);
}
if (semNome.length) console.warn(`${semNome.length} linha(s) sem nome foram puladas.`);

/* Ordem por instituição e depois por nome: a pilha chega agrupada
   por estande, que é como ela vai ser distribuída. */
const comparar = (a, b) => a.localeCompare(b, 'pt-BR', { sensitivity: 'base' });
pessoas.sort((a, b) => comparar(a.organizacao, b.organizacao) || comparar(a.nome, b.nome));

/* O logo vai embutido para o arquivo abrir e imprimir em qualquer
   máquina, sem depender da pasta do projeto. */
const logo = 'data:image/png;base64,' + readFileSync('logo-email.png').toString('base64');

const cartao = p => `
    <div class="cracha">
      <div class="info">
        <p class="nome">${escapar(p.nome)}</p>
        <p class="org">${escapar(p.organizacao)}</p>
        <p class="papel">${escapar(etiqueta(p.tipo))}</p>
      </div>
      <div class="logo"><img src="${logo}" alt=""></div>
    </div>`;

const html = `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>Crachás — Representantes</title>
<style>
  @page { size: A4; margin: 8mm; }
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
    width: 160mm; margin: 0 auto 16px; background: #fff;
    display: grid; grid-template-columns: repeat(2, 80mm); gap: 0;
  }
  .cracha {
    width: 80mm; height: 40mm;
    padding: 3mm;
    border: 1px dashed #b8bfc9;   /* guia de corte */
    display: flex; flex-direction: row; align-items: center; gap: 2mm;
    break-inside: avoid; page-break-inside: avoid;
  }
  .info  { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1mm; }
  .nome  { font-size: 11.5pt; font-weight: 700; margin: 0; line-height: 1.15; overflow-wrap: anywhere; }
  .org   { font-size: 8pt; color: #4a5361; margin: 0; line-height: 1.25; overflow-wrap: anywhere; }
  .papel { font-size: 5.5pt; letter-spacing: .16em; text-transform: uppercase; color: #6b7482;
           margin: .5mm 0 0; }
  .logo  { width: 24mm; flex: none; display: flex; align-items: center; justify-content: center; }
  .logo img { width: 100%; height: auto; display: block; }
  @media print {
    body { background: #fff; }
    .instrucoes { display: none; }
    .folha { width: auto; margin: 0; }
    .cracha { border-color: #d0d5dc; }
  }
</style>
</head>
<body>

<div class="instrucoes">
  <p><b>Representantes: ${pessoas.length} crachás.</b>
  Imprima com <b>Ctrl+P</b> → Salvar como PDF. Nas opções, marque <b>"Gráficos de fundo"</b>
  (sem isso o logo não sai) e deixe a escala em <b>100%</b>, para o crachá sair em 80 x 40mm
  como o dos alunos.</p>
  <p>As linhas tracejadas são guia de corte. Este crachá não tem QR: o representante escaneia,
  não é escaneado.</p>
</div>

<div class="folha">${pessoas.map(cartao).join('')}
</div>

</body>
</html>
`;

mkdirSync('saida', { recursive: true });
writeFileSync(SAIDA, html);

console.log(`${pessoas.length} crachá(s) em ${SAIDA}`);
for (const p of pessoas) console.log(`  ${p.nome.padEnd(28)} ${p.organizacao}`);
console.log('\nAbra no navegador e imprima com Ctrl+P (escala 100%, gráficos de fundo ligados).');
