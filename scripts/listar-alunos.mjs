/* ============================================================
   Lista dos alunos por unidade, em planilha

   Lê os alunos ativos no Supabase e escreve uma planilha .xlsx
   por unidade em saida/: nome, série, contatos, código do crachá,
   leva em que o crachá saiu e presença (quando o evento já
   aconteceu). Serve para a secretaria conferir quem está na
   plataforma e para a mesa de entrada ter a lista em papel.

   Sem npm install: o .xlsx sai do xlsx.mjs do projeto.

   USO (PowerShell, com segredo-supabase.txt na raiz):
     node scripts/listar-alunos.mjs                        # todas as unidades
     node scripts/listar-alunos.mjs --unidade "Recreio"    # só uma

   Saída: saida/alunos-<unidade>.xlsx (um arquivo por unidade).
   Contém nome e contato de menores — não publique, apague depois
   de usar.
   ============================================================ */

import { writeFileSync, mkdirSync } from 'node:fs';
import { exigirChave, exigirUrl } from './chave.mjs';
import { montarXlsx } from './xlsx.mjs';

const URL_PROJETO = exigirUrl();
const argumentos = process.argv.slice(2);
const CHAVE = exigirChave();

const textoDe = nome => {
  const i = argumentos.findIndex(a => a === nome || a.startsWith(nome + '='));
  if (i < 0) return null;
  const bruto = argumentos[i].includes('=') ? argumentos[i].slice(nome.length + 1) : argumentos[i + 1];
  const t = String(bruto || '').trim();
  if (!t) { console.error(`${nome} precisa de um valor. Ex.: ${nome} "Recreio"`); process.exit(1); }
  return t;
};
const UNIDADE = textoDe('--unidade');

async function apiTudo(caminho) {
  const tudo = [];
  for (let de = 0; ; de += 1000) {
    const r = await fetch(`${URL_PROJETO}/rest/v1/${caminho}`, {
      headers: { apikey: CHAVE, Authorization: 'Bearer ' + CHAVE, Range: `${de}-${de + 999}` }
    });
    if (!r.ok) throw new Error(await r.text());
    const pagina = await r.json();
    tudo.push(...pagina);
    if (pagina.length < 1000) return tudo;
  }
}

/* Ordem das séries como a escola fala: 6º, 7º, 8º, 9º Ano e depois
   1ª, 2ª, 3ª Série. Alfabética poria "1ª Série" antes de "8º Ano". */
const pesoSerie = s => {
  const t = String(s || '');
  const n = parseInt(t, 10) || 99;
  return (/s[ée]rie/i.test(t) ? 10 : 0) + n;
};
const comparar = (a, b) => String(a || '').localeCompare(String(b || ''), 'pt-BR', { sensitivity: 'base' });

const limpo = s => String(s || 'sem-unidade').normalize('NFD').replace(/\p{M}/gu, '')
  .replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase();

const COLUNAS = [
  { titulo: 'Nome',                  chave: 'nome' },
  { titulo: 'Série',                 chave: 'ano_escolaridade' },
  { titulo: 'E-mail',                chave: 'email' },
  { titulo: 'Telefone',              chave: 'telefone' },
  { titulo: 'Responsável',           chave: 'responsavel_nome' },
  { titulo: 'E-mail do responsável', chave: 'responsavel_email' },
  { titulo: 'Código do crachá',      chave: 'codigo_curto' },
  { titulo: 'Leva do crachá',        chave: 'cracha_lote', tipo: 'numero' },
  { titulo: 'Presente',              chave: 'presente_txt' },
  { titulo: 'Entrou em',             chave: 'presente_em_txt' }
];

const dataBr = iso => iso ? new Date(iso).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' }) : '';

async function principal() {
  const filtro = UNIDADE ? `&unidade=eq.${encodeURIComponent(UNIDADE)}` : '';
  const alunos = await apiTudo(
    'alunos?select=nome,unidade,ano_escolaridade,email,telefone,responsavel_nome,responsavel_email,' +
    `codigo_curto,cracha_lote,presente,presente_em&ativo=eq.true&tipo=eq.aluno${filtro}`);

  if (!alunos.length) {
    console.error(UNIDADE ? `Nenhum aluno ativo na unidade "${UNIDADE}" (a grafia precisa ser idêntica à do banco).`
                          : 'Nenhum aluno ativo no banco.');
    process.exit(1);
  }

  const porUnidade = new Map();
  for (const a of alunos) {
    const u = a.unidade || 'Sem unidade';
    if (!porUnidade.has(u)) porUnidade.set(u, []);
    porUnidade.get(u).push({
      ...a,
      presente_txt: a.presente ? 'Sim' : '',
      presente_em_txt: dataBr(a.presente_em)
    });
  }

  mkdirSync('saida', { recursive: true });
  for (const [unidade, lista] of [...porUnidade].sort((x, y) => comparar(x[0], y[0]))) {
    lista.sort((a, b) =>
      pesoSerie(a.ano_escolaridade) - pesoSerie(b.ano_escolaridade) ||
      comparar(a.ano_escolaridade, b.ano_escolaridade) ||
      comparar(a.nome, b.nome));

    const arquivo = `saida/alunos-${limpo(unidade)}.xlsx`;
    writeFileSync(arquivo, montarXlsx([{ nome: unidade.slice(0, 31), colunas: COLUNAS, linhas: lista }]));

    const porSerie = {};
    for (const a of lista) porSerie[a.ano_escolaridade || '?'] = (porSerie[a.ano_escolaridade || '?'] || 0) + 1;
    console.log(`${arquivo} — ${lista.length} aluno(s)`);
    for (const [s, n] of Object.entries(porSerie).sort((x, y) => pesoSerie(x[0]) - pesoSerie(y[0])))
      console.log(`    ${String(n).padStart(4)}  ${s}`);
  }
  console.log('\nAs planilhas têm contato de menores: não publique e apague depois de usar.');
}

principal().catch(e => { console.error('Erro: ' + (e.message || e)); process.exit(1); });
