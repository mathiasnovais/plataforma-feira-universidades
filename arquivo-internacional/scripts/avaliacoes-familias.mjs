/* ============================================================
   Resultado da pesquisa das famílias

   Lê o que a avaliacao-familias.html gravou (migration 0053) e
   escreve saida/avaliacoes-familias.xlsx com três abas: resumo com
   as médias, respostas linha a linha e os comentários abertos
   separados.

   USO:
     node scripts/avaliacoes-familias.mjs

   POR QUE ARQUIVO SEPARADO DO scripts/avaliacoes.mjs

   São dois públicos e dois questionários diferentes. Juntar numa
   planilha só renderia colunas vazias de um lado e do outro, e uma
   média geral que mistura quem montou estande com quem levou o
   filho no sábado de manhã — número que não responde pergunta
   nenhuma.

   AS RESPOSTAS SÃO ANÔNIMAS

   Não há coluna de nome, e-mail ou turma, e não existe em lugar
   nenhum uma lista de quem respondeu. O link é um código único
   para todas as famílias. A coluna `perfil` (responsável, aluno ou
   os dois juntos) separa dois olhares; não identifica ninguém.
   ============================================================ */

import { writeFileSync, mkdirSync } from 'node:fs';
import { exigirChave, exigirUrl } from './chave.mjs';
import { montarXlsx } from './xlsx.mjs';

const URL_PROJETO = exigirUrl();
const CHAVE = exigirChave();

/* Erro aqui NÃO chama process.exit(): no Node do Windows, sair logo
   depois de um fetch estoura em "Assertion failed" e devolve código
   127, soterrando a mensagem escrita com cuidado. Marcar
   process.exitCode e deixar o programa terminar sozinho sai limpo. */
class Parar extends Error {}

async function ler(caminho) {
  const r = await fetch(`${URL_PROJETO}/rest/v1/${caminho}`, {
    headers: { apikey: CHAVE, Authorization: 'Bearer ' + CHAVE }
  });
  if (!r.ok) {
    const texto = await r.text();
    if (/avaliacoes_familias|pesquisa_familias/.test(texto)) {
      throw new Parar('A pesquisa das famílias ainda não existe no banco.\n' +
        'Rode supabase/migrations/0053_pesquisa_familias.sql no SQL Editor.');
    }
    throw new Parar(`Falha ao ler ${caminho}: ${texto}`);
  }
  return r.json();
}

const dados = await (async () => ({
  respostas: await ler('avaliacoes_familias?select=*&order=criado_em'),
  config:    await ler('pesquisa_familias?select=codigo,aberta')
}))().catch(e => {
  console.error(e instanceof Parar ? e.message : e);
  process.exitCode = 1;
  return null;
});

if (!dados) {
  console.error('\nNada foi gerado.');
} else {

const respostas = dados.respostas;
const config = dados.config[0] || null;

/* ------------------------------------------------------------
   As seis questões, na ordem do formulário em papel
   ------------------------------------------------------------ */
const NOTAS = [
  ['q1_geral',         'Experiência geral'],
  ['q2_organizacao',   'Organização e circulação'],
  ['q3_universidades', 'Qualidade e diversidade das universidades'],
  ['q4_contribuicao',  'Contribuição para as decisões da família'],
  ['q5_valor',         'Valor de iniciativas como esta']
];

const PERFIL = {
  responsavel: 'Responsável',
  aluno: 'Aluno(a)',
  ambos: 'Responderam juntos'
};

const col = (chave, titulo, tipo) => ({ chave, titulo, tipo });

const quando = iso => !iso ? '' : new Date(iso).toLocaleString('pt-BR', {
  timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric',
  hour: '2-digit', minute: '2-digit'
}).replace(',', '');

/* ---- aba 2: uma linha por resposta ---- */
const COLUNAS = [
  col('n', 'Resposta nº', 'numero'),
  col('perfil', 'Quem respondeu'),
  ...NOTAS.map(([c, t]) => col(c, t, 'numero')),
  col('q6_ponto_forte', 'Principal ponto positivo'),
  col('q6_melhoria',    'Melhoria mais importante'),
  col('respondido_em',  'Respondido em', 'data')
];

const linhas = respostas.map((r, i) => {
  const linha = {
    n: i + 1,
    perfil: PERFIL[r.perfil] || '—',
    q6_ponto_forte: r.q6_ponto_forte,
    q6_melhoria: r.q6_melhoria,
    respondido_em: quando(r.criado_em)
  };
  for (const [c] of NOTAS) linha[c] = r[c];
  return linha;
});

/* ------------------------------------------------------------
   Resumo

   Média ignorando nulo — que é como "não respondi" foi gravado.
   Contar quantos responderam cada item ao lado da média é o que
   impede a leitura errada: 5,0 de uma resposta só não é a mesma
   notícia que 4,2 de trezentas.

   As colunas por perfil existem porque a mesma pergunta produz
   respostas diferentes na boca de quem levou o filho e na boca de
   quem foi levado.
   ------------------------------------------------------------ */
const media = (lista, chave) => {
  const v = lista.map(r => r[chave]).filter(x => x !== null && x !== undefined);
  return v.length ? Math.round((v.reduce((s, x) => s + x, 0) / v.length) * 100) / 100 : null;
};

const doPerfil = p => respostas.filter(r => r.perfil === p);

const resumo = NOTAS.map(([chave, titulo]) => {
  const vals = respostas.map(r => r[chave]).filter(v => v !== null && v !== undefined);
  return {
    item: titulo,
    media: media(respostas, chave),
    respostas: vals.length,
    menor: vals.length ? Math.min(...vals) : null,
    maior: vals.length ? Math.max(...vals) : null,
    m_responsavel: media(doPerfil('responsavel'), chave),
    m_aluno: media(doPerfil('aluno'), chave),
    m_ambos: media(doPerfil('ambos'), chave)
  };
});

const COLUNAS_RESUMO = [
  col('item',          'Item'),
  col('media',         'Média geral', 'numero'),
  col('respostas',     'Respostas',   'numero'),
  col('menor',         'Menor nota',  'numero'),
  col('maior',         'Maior nota',  'numero'),
  col('m_responsavel', 'Média · responsáveis', 'numero'),
  col('m_aluno',       'Média · alunos',       'numero'),
  col('m_ambos',       'Média · juntos',       'numero')
];

/* ---- aba 3: só os comentários ----
   Quem vai ler as respostas abertas quer lê-las em sequência, sem
   atravessar dezoito colunas de nota para chegar na próxima. */
const comentarios = [];
respostas.forEach((r, i) => {
  if (r.q6_ponto_forte) {
    comentarios.push({ n: i + 1, perfil: PERFIL[r.perfil] || '—',
                       tipo: 'Ponto positivo', texto: r.q6_ponto_forte });
  }
  if (r.q6_melhoria) {
    comentarios.push({ n: i + 1, perfil: PERFIL[r.perfil] || '—',
                       tipo: 'Melhoria', texto: r.q6_melhoria });
  }
});

const COLUNAS_COMENTARIOS = [
  col('n',      'Resposta nº', 'numero'),
  col('perfil', 'Quem respondeu'),
  col('tipo',   'Tipo'),
  col('texto',  'Comentário')
];

mkdirSync('saida', { recursive: true });
writeFileSync('saida/avaliacoes-familias.xlsx', montarXlsx([
  { nome: 'Resumo',      colunas: COLUNAS_RESUMO,      linhas: resumo },
  { nome: 'Respostas',   colunas: COLUNAS,             linhas },
  { nome: 'Comentários', colunas: COLUNAS_COMENTARIOS, linhas: comentarios }
]));

/* ---- resumo no terminal ---- */
console.log(`${respostas.length} resposta(s) em saida/avaliacoes-familias.xlsx`);

if (respostas.length) {
  const porPerfil = Object.entries(PERFIL)
    .map(([k, r]) => `${doPerfil(k).length} ${r.toLowerCase()}`)
    .join(' · ');
  console.log(`  ${porPerfil} · ${respostas.filter(r => !r.perfil).length} sem perfil`);
  console.log(`  experiência geral: ${media(respostas, 'q1_geral') ?? '—'} de 5`);
  console.log(`  valor da iniciativa: ${media(respostas, 'q5_valor') ?? '—'} de 5`);
  console.log(`  ${comentarios.length} comentário(s) aberto(s)`);
}

if (config) {
  console.log(`\nPesquisa ${config.aberta ? 'ABERTA' : 'ENCERRADA'} · código ${config.codigo}`);
  if (!config.aberta) {
    console.log('  Para reabrir: update pesquisa_familias set aberta = true;');
  }
}
console.log('\nAs respostas são anônimas: não há como saber de quem é cada linha.');

}
