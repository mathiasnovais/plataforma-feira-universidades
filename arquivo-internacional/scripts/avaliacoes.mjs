/* ============================================================
   Resultado da pesquisa de feedback das universidades

   Lê as respostas gravadas pela avaliacao.html (migration 0049) e
   escreve saida/avaliacoes.xlsx com duas abas — uma linha por
   instituição e um resumo com as médias — mais quem ainda não
   respondeu.

   USO:
     node scripts/avaliacoes.mjs

   POR QUE UM SCRIPT, E NÃO UMA TELA

   `avaliacoes_evento` tem RLS ligada e nenhuma policy, como
   `alunos`: ninguém lê direto, nem logado. Uma tela exigiria mais
   uma função SECURITY DEFINER e mais uma rota de acesso a dado —
   para uma leitura que acontece meia dúzia de vezes na vida do
   evento. Aqui a chave fica na variável de ambiente e o resultado
   sai em planilha.

   AS RESPOSTAS SÃO ANÔNIMAS

   A planilha NÃO tem coluna de instituição, nem de data. Não é
   esquecimento: a 0051 cortou o vínculo entre resposta e
   respondente porque o convite promete anonimato em duas línguas.
   Não há de onde tirar essa coluna.

   O que dá para saber é QUEM já respondeu — a aba "Faltam
   responder" sai da marca em `avaliadores.respondeu_pesquisa_em`,
   que vive noutra tabela e não aponta para linha nenhuma de
   resposta. Lista de quem votou, sim; voto de cada um, não.
   ============================================================ */

import { writeFileSync, mkdirSync } from 'node:fs';
import { exigirChave, exigirUrl } from './chave.mjs';
import { montarXlsx } from './xlsx.mjs';

const URL_PROJETO = exigirUrl();
const CHAVE = exigirChave();

/* Erro aqui NÃO chama process.exit().

   No Node do Windows, sair com process.exit() logo depois de um
   fetch estoura em "Assertion failed: !(handle->flags &
   UV_HANDLE_CLOSING)" e devolve código 127: a mensagem de erro
   escrita com cuidado logo acima fica soterrada, e quem chamar o
   script de dentro de outro vê 127, que quer dizer "comando não
   encontrado". Marcar process.exitCode e deixar o programa
   terminar sozinho sai limpo e devolve 1. */
class Parar extends Error {}

async function ler(caminho) {
  const r = await fetch(`${URL_PROJETO}/rest/v1/${caminho}`, {
    headers: { apikey: CHAVE, Authorization: 'Bearer ' + CHAVE }
  });
  if (!r.ok) {
    const texto = await r.text();
    if (/avaliacoes_evento|avaliacao_token/.test(texto)) {
      throw new Parar('A pesquisa ainda não existe no banco.\n' +
        'Rode supabase/migrations/0049_avaliacao_evento.sql no SQL Editor.');
    }
    throw new Parar(`Falha ao ler ${caminho}: ${texto}`);
  }
  return r.json();
}

/* Sem `order`: a ordem de leitura é a ordem física das linhas, que
   é a ordem de inserção. Ordenar por qualquer coisa não ajudaria a
   esconder isso, e é a fresta que a 0051 documenta — a única que
   sobrou, e só alcançável por quem tem o banco. */
const dados = await (async () => ({
  respostas:   await ler('avaliacoes_evento?select=*'),
  avaliadores: await ler(
    'avaliadores?select=id,nome,email,organizacao,papel,presente,respondeu_pesquisa_em' +
    '&order=id&limit=1000')
}))().catch(e => {
  console.error(e instanceof Parar ? e.message : e);
  process.exitCode = 1;
  return null;
});

const respostas = dados ? dados.respostas : [];
const avaliadores = dados ? dados.avaliadores : [];


/* ------------------------------------------------------------
   As perguntas, na ordem do formulário

   Mesma lista da avaliacao.html. Se uma pergunta mudar lá, muda
   aqui — são os dois lados do mesmo formulário.
   ------------------------------------------------------------ */
const NOTAS = [
  ['q1_geral',          'Experiência geral',            'Overall experience'],
  ['q2_pre_evento',     'Comunicação pré-evento',       'Pre-event communication'],
  ['q3_chegada',        'Chegada e credenciamento',     'Arrival & check-in'],
  ['q3_estande_espaco', 'Espaço do estande',            'Booth space'],
  ['q3_estande_local',  'Localização do estande',       'Booth location'],
  ['q3_sinalizacao',    'Sinalização',                  'Signage'],
  ['q3_fluxo',          'Fluxo de visitantes',          'Visitor flow'],
  ['q3_infra_tecnica',  'Infraestrutura técnica',       'Technical infrastructure'],
  ['q3_suporte',        'Suporte da equipe',            'Team support'],
  ['q3_organizacao',    'Organização geral',            'Overall organization'],
  ['q4_interesse',      'Alunos: interesse',            'Students: interest'],
  ['q4_perguntas',      'Alunos: qualidade das perguntas', 'Students: questions'],
  ['q4_confianca',      'Alunos: confiança',            'Students: confidence'],
  ['q4_consciencia',    'Alunos: conhecimento',         'Students: awareness'],
  ['q4_geral',          'Alunos: interação geral',      'Students: overall'],
  ['q5_ingles',         'Inglês dos alunos',            "Students' English"],
  ['q6_acesso',         'Plataforma: acesso',           'Platform: access'],
  ['q6_uso',            'Plataforma: uso',              'Platform: ease of use'],
  ['q6_captura',        'Plataforma: captação',         'Platform: lead capture'],
  ['q6_confiabilidade', 'Plataforma: confiabilidade',   'Platform: reliability'],
  ['q6_utilidade',      'Plataforma: utilidade',        'Platform: usefulness'],
  ['q7_valor',          'Valor da participação',        'Value of participating'],
  ['q8_voltaria',       'Probabilidade de voltar (0-10)', 'Likelihood to return (0-10)']
];

const col = (chave, pt, en, tipo) => ({ chave, titulo: `${pt} / ${en}`, tipo });

/* Sem instituição, sem respondente e sem data — não existem no
   banco. A primeira coluna é só um número de linha, para dar como
   referir uma resposta numa reunião ("a resposta 7 diz que...")
   sem precisar de nome. */
const COLUNAS = [
  col('n', 'Resposta nº', 'Response #', 'numero'),
  ...NOTAS.map(([c, pt, en]) => col(c, pt, en, 'numero')),
  col('q9_ponto_forte', 'Ponto positivo',     'Strongest aspect'),
  col('q9_melhoria',    'Melhoria sugerida',  'Suggested improvement'),
  col('q10_interesses', 'Interesses futuros', 'Future interests')
];

const linhas = respostas.map((r, i) => {
  const linha = {
    n: i + 1,
    q9_ponto_forte: r.q9_ponto_forte,
    q9_melhoria: r.q9_melhoria,
    q10_interesses: (r.q10_interesses || []).join(', ')
  };
  for (const [c] of NOTAS) linha[c] = r[c];
  return linha;
});

/* ------------------------------------------------------------
   Resumo

   Média ignorando nulo — que é como N/A e "não respondi" foram
   gravados. Contar quantos responderam cada item ao lado da média
   é o que impede a leitura errada: 5,0 de uma resposta só não é
   a mesma notícia que 4,2 de trinta.
   ------------------------------------------------------------ */
const resumo = NOTAS.map(([chave, pt, en]) => {
  const vals = respostas.map(r => r[chave]).filter(v => v !== null && v !== undefined);
  const media = vals.length ? vals.reduce((s, v) => s + v, 0) / vals.length : null;

  return {
    item: `${pt} / ${en}`,
    media: media === null ? null : Math.round(media * 100) / 100,
    respostas: vals.length,
    menor: vals.length ? Math.min(...vals) : null,
    maior: vals.length ? Math.max(...vals) : null
  };
});

const COLUNAS_RESUMO = [
  col('item',      'Item',            'Item'),
  col('media',     'Média',           'Average',  'numero'),
  col('respostas', 'Respostas',       'Responses', 'numero'),
  col('menor',     'Menor nota',      'Lowest',   'numero'),
  col('maior',     'Maior nota',      'Highest',  'numero')
];

/* Quem ainda não respondeu — a lista de cobrança. Vem da marca em
   `avaliadores`, não da tabela de respostas: é justamente a
   separação que mantém o anonimato de pé.

   Só quem esteve presente: cobrar resposta de quem não foi à
   feira não faz sentido e queima o contato. */
const faltam = avaliadores
  .filter(a => a.papel === 'avaliador' && a.presente && !a.respondeu_pesquisa_em)
  .map(a => ({ instituicao: a.organizacao || '—', quem: a.nome, email: a.email }));

const COLUNAS_FALTAM = [
  col('instituicao', 'Instituição', 'Institution'),
  col('quem',        'Representante', 'Representative'),
  col('email',       'E-mail',      'Email')
];

/* Leitura falhou: a mensagem já foi impressa e o código de saída
   já está marcado. Não escreve planilha vazia por cima da boa. */
if (!dados) {
  console.error('\nNada foi gerado.');
} else {

mkdirSync('saida', { recursive: true });
writeFileSync('saida/avaliacoes.xlsx', montarXlsx([
  { nome: 'Resumo – Summary',   colunas: COLUNAS_RESUMO, linhas: resumo },
  { nome: 'Respostas – Answers', colunas: COLUNAS,       linhas },
  { nome: 'Faltam responder',   colunas: COLUNAS_FALTAM, linhas: faltam }
]));

/* ---- resumo no terminal ---- */
const media = c => {
  const v = respostas.map(r => r[c]).filter(x => x !== null && x !== undefined);
  return v.length ? (v.reduce((s, x) => s + x, 0) / v.length).toFixed(2) : '—';
};

console.log(`${respostas.length} resposta(s) em saida/avaliacoes.xlsx`);
if (respostas.length) {
  console.log(`  experiência geral: ${media('q1_geral')} de 5`);
  console.log(`  valor da participação: ${media('q7_valor')} de 5`);
  console.log(`  probabilidade de voltar: ${media('q8_voltaria')} de 10`);
  console.log(`  plataforma (captação de leads): ${media('q6_captura')} de 5`);
}
console.log(`  ${faltam.length} representante(s) presente(s) ainda não responderam.`);
console.log('\nAs respostas são identificadas por instituição.');

}
