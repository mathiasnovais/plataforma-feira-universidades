/* ============================================================
   Conferência das inscrições duplicadas

   O painel avisa QUE existe duplicata; este script mostra o que
   é preciso para decidir o que fazer com cada uma, e escreve o
   SQL da limpeza para você revisar antes de rodar.

   USO (PowerShell):
     node scripts/duplicatas.mjs

   A chave vem de segredo-supabase.txt (veja scripts/chave.mjs).

   POR QUE NÃO DÁ PARA DECIDIR PELA LISTA DO PAINEL

   O painel agrupa por chave_nome() — primeiro + último nome, sem
   acento nem caixa (0024). É proposital: pega "Ana Beatriz Silva"
   e "Ana Silva" como a mesma pessoa. Em troca, junta no mesmo
   grupo duas pessoas diferentes que só compartilham o primeiro e
   o último nome. Duas "Maria ... Nascimento" sem parentesco
   nenhuma aparecem lado a lado ali.

   Separar uma coisa da outra exige olhar série, unidade,
   responsável e telefone — que é o que este script traz.

   POR QUE ELE NÃO APAGA NADA

   `delete from alunos` cascateia para `acompanhantes` (0012).
   Apagar a linha errada leva junto os acompanhantes que só
   estavam nela, e ninguém percebe: some do banco e some do
   crachá, sem erro nenhum na tela. O roteiro sai em
   saida/duplicatas.sql, para ser lido antes de ser executado.

   ATENÇÃO: a saída tem nome, e-mail e telefone de menores de
   idade. Mesma regra do crachá — não publique, apague depois.
   ============================================================ */

import { writeFileSync, mkdirSync } from 'node:fs';
import { exigirChave, exigirUrl } from './chave.mjs';

const URL_PROJETO = exigirUrl();
const CHAVE = exigirChave();

/* Em páginas: o PostgREST tem teto de linhas por resposta e a
   resposta truncada não vem marcada como erro — vem como uma
   lista curta. Um grupo de duplicata cortado ao meio viraria uma
   inscrição "sem par" e passaria batido. */
async function ler(caminho) {
  const PAGINA = 1000;
  const linhas = [];

  for (let de = 0; ; de += PAGINA) {
    const r = await fetch(`${URL_PROJETO}/rest/v1/${caminho}`, {
      headers: {
        apikey: CHAVE,
        Authorization: 'Bearer ' + CHAVE,
        'Range-Unit': 'items',
        Range: `${de}-${de + PAGINA - 1}`
      }
    });

    if (!r.ok) {
      console.error(`Falha ao ler ${caminho}:`, await r.text());
      process.exit(1);
    }

    const parte = await r.json();
    linhas.push(...parte);
    if (parte.length < PAGINA) return linhas;
  }
}

const alunos = await ler(
  'alunos?select=id,nome,tipo,ano_escolaridade,unidade,colegio,aluno_alfacem,' +
  'email,telefone,responsavel_nome,responsavel_email,responsavel_telefone,' +
  'consentimento_responsavel,ativo,presente,codigo_curto,cracha_lote,criado_em,' +
  'acompanhantes(id,nome,parentesco)&order=criado_em'
);

/* ---------------------------------------------------------- */

/* NFD separa a letra do acento; \p{M} varre os acentos soltos que
   sobram. 'José' e 'Jose' passam a ser a mesma coisa na hora de
   comparar — só na comparação, nunca no que é exibido. */
const semAcento = t => String(t == null ? '' : t).normalize('NFD').replace(/\p{M}/gu, '');
const normal = t => semAcento(t).toLowerCase().replace(/\s+/g, ' ').trim();

/* Mesma regra do chave_nome() do banco (0024): primeiro + último,
   sem acento e sem caixa. Tem que ser a mesma, senão este script
   e o painel discordariam sobre o que é um grupo — e a pessoa que
   conferisse os dois não saberia em qual acreditar. */
const chaveNome = nome => {
  const partes = normal(nome).split(' ').filter(Boolean);
  if (!partes.length) return null;
  return partes.length > 1 ? `${partes[0]} ${partes[partes.length - 1]}` : partes[0];
};

const contato = a => normal(a.responsavel_email || a.email || '');
const fone = a => semAcento(a.responsavel_telefone || a.telefone || '').replace(/\D/g, '');

/* Distância de edição, para pegar e-mail digitado errado na
   segunda vez: 'fsn1rj@gmail.com' e 'fsn1rj@gmail.comf' são a
   mesma família, não duas. Acima de 2 caracteres de diferença já
   é outro endereço e a conta para no primeiro `if`. */
function distancia(a, b) {
  if (Math.abs(a.length - b.length) > 2) return 9;
  let anterior = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const atual = [i];
    for (let j = 1; j <= b.length; j++) {
      atual[j] = Math.min(
        anterior[j] + 1,
        atual[j - 1] + 1,
        anterior[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    anterior = atual;
  }
  return anterior[b.length];
}

/* ---- montar os grupos ---- */

const grupos = new Map();
for (const a of alunos) {
  const k = chaveNome(a.nome);
  if (!k) continue;
  if (!grupos.has(k)) grupos.set(k, []);
  grupos.get(k).push(a);
}

const repetidos = [...grupos.entries()].filter(([, linhas]) => linhas.length > 1);

if (!repetidos.length) {
  console.log('Nenhum nome repetido. Nada a conferir.');
  process.exit(0);
}

/* ---- classificar ----

   Três veredictos, e só os dois primeiros viram SQL:

   CERTA      mesma pessoa, sem dúvida razoável. Nome completo
              idêntico e o mesmo contato (ou o mesmo contato com
              erro de digitação).

   PROVAVEL   nome completo idêntico, contatos diferentes. Quase
              sempre é pai e mãe preenchendo cada um o seu. Mas
              "quase sempre" não é sempre, e telefone ou unidade
              diferentes mudam a resposta — por isso vem separado.

   VERIFICAR  só o primeiro e o último nome batem. É o falso
              positivo do agrupamento. Não gera SQL nenhum. */

const veredicto = linhas => {
  const nomes = new Set(linhas.map(a => normal(a.nome)));
  const tipos = new Set(linhas.map(a => a.tipo || 'aluno'));

  if (nomes.size > 1) return ['VERIFICAR', 'nomes completos diferentes — provável homônimo'];
  if (tipos.size > 1) return ['VERIFICAR', 'tipos diferentes (aluno/counselor/docente) — pessoas diferentes'];

  const contatos = [...new Set(linhas.map(contato).filter(Boolean))];

  if (contatos.length <= 1) return ['CERTA', 'mesmo nome e mesmo contato'];

  const parecidos = contatos.every(c => distancia(c, contatos[0]) <= 2);
  if (parecidos) return ['CERTA', 'mesmo nome e mesmo contato com erro de digitação'];

  const fones = [...new Set(linhas.map(fone).filter(Boolean))];
  if (fones.length === 1) return ['CERTA', 'mesmo nome e mesmo telefone, contatos diferentes'];

  return ['PROVAVEL', 'mesmo nome completo, contatos diferentes — confirme com a família'];
};

/* Qual linha fica.

   A ordem dos pesos é a ordem do estrago: crachá já impresso
   circula no mundo e não dá para chamar de volta; presença já
   marcada é registro do dia; inscrição ativa já passou pela
   revisão. Só abaixo disso entra "qual está mais completa". */
const pontos = a =>
    (a.cracha_lote ? 32 : 0)
  + (a.presente ? 16 : 0)
  + (a.ativo ? 8 : 0)
  + (a.acompanhantes || []).length * 4
  + (a.consentimento_responsavel ? 2 : 0)
  + (contato(a) ? 1 : 0);

const melhor = linhas => [...linhas].sort((x, y) =>
  pontos(y) - pontos(x) ||
  /* Empatou: fica a última. Quem preencheu duas vezes costuma ter
     corrigido algo na segunda — é o mesmo critério da 0024. */
  new Date(y.criado_em) - new Date(x.criado_em))[0];

/* ---------------------------------------------------------- */

const data = t => t ? new Date(t).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—';
const escola = a => a.unidade || a.colegio || (a.aluno_alfacem === false ? 'colégio externo' : '—');

const ORDEM = { CERTA: 0, PROVAVEL: 1, VERIFICAR: 2 };
const analisados = repetidos
  .map(([chave, linhas]) => {
    const [classe, motivo] = veredicto(linhas);
    return { chave, linhas, classe, motivo, fica: melhor(linhas) };
  })
  .sort((a, b) => ORDEM[a.classe] - ORDEM[b.classe] || a.chave.localeCompare(b.chave));

const contagem = { CERTA: 0, PROVAVEL: 0, VERIFICAR: 0 };
for (const g of analisados) contagem[g.classe]++;

const linhasSql = [];
const letra = i => String.fromCharCode(65 + i);

for (const g of analisados) {
  console.log('');
  console.log('─'.repeat(78));
  console.log(`${g.classe}  —  ${g.motivo}`);

  g.linhas.forEach((a, i) => {
    const marca = g.classe === 'VERIFICAR' ? ' ' : (a.id === g.fica.id ? '✓' : '✗');
    const acomp = (a.acompanhantes || []).map(c =>
      `${c.nome}${c.parentesco ? ` (${c.parentesco})` : ''}`).join(', ');

    console.log('');
    console.log(` ${marca} ${letra(i)}  ${a.nome}`);
    console.log(`      ${[a.tipo && a.tipo !== 'aluno' ? a.tipo : null, a.ano_escolaridade, escola(a)]
      .filter(Boolean).join(' · ')}`);
    console.log(`      resp. ${a.responsavel_nome || '—'} · ${a.responsavel_email || a.email || 'sem contato'}` +
                `${a.responsavel_telefone || a.telefone ? ' · ' + (a.responsavel_telefone || a.telefone) : ''}`);
    console.log(`      acompanhantes: ${acomp || 'nenhum'}`);
    console.log(`      ${a.ativo ? 'ativo' : 'AGUARDANDO REVISÃO'}` +
                `${a.consentimento_responsavel ? '' : ' · SEM CONSENTIMENTO'}` +
                `${a.cracha_lote ? ` · crachá impresso na leva ${a.cracha_lote}` : ''}` +
                `${a.presente ? ' · presente' : ''}` +
                ` · ${a.codigo_curto} · inscrito em ${data(a.criado_em)}`);
  });

  if (g.classe === 'VERIFICAR') {
    console.log('');
    console.log('   → nada a fazer sem confirmar. Se forem mesmo duas pessoas, ignore este grupo.');
    continue;
  }

  const apagar = g.linhas.filter(a => a.id !== g.fica.id);
  const iFica = g.linhas.indexOf(g.fica);
  console.log('');
  console.log(`   → sugestão: manter ${letra(iFica)}, apagar ` +
              apagar.map(a => letra(g.linhas.indexOf(a))).join(' e '));

  /* Acompanhante preso na linha que vai sumir precisa mudar de
     dono ANTES do delete, senão o cascade o leva junto.

     A comparação é por chaveNome, não pelo nome inteiro: a mãe
     escreve o pai como "Marcelo Assumpção" e o pai se escreve
     "Marcelo de Azevedo Lopes Assumpção". Comparando texto cru
     ele mudaria de dono e o filho ficaria com o pai duas vezes —
     dois crachás para o mesmo homem, que é o problema que este
     script existe para evitar. */
  const orfaos = apagar.flatMap(a => (a.acompanhantes || []).map(c => ({ ...c, de: a })));
  const jaTem = new Set((g.fica.acompanhantes || []).map(c => chaveNome(c.nome)));
  const mudarDeDono = orfaos.filter(c => !jaTem.has(chaveNome(c.nome)));

  if (mudarDeDono.length) {
    console.log(`   → ${mudarDeDono.length} acompanhante(s) só existem na linha que sai ` +
                `(${mudarDeDono.map(c => c.nome).join(', ')}) — o SQL move antes de apagar.`);
  }
  if (jaTem.size + mudarDeDono.length > 3) {
    console.log('   ⚠ juntando passa de 3 acompanhantes, que é o limite do formulário (0012).');
    console.log('     O UPDATE não é barrado pelo trigger, mas confira se todos vão mesmo.');
  }

  /* PROVAVEL sai comentado. O arquivo inteiro colado de uma vez
     no SQL Editor é o uso mais provável dele, e nesse caso o que
     ainda depende de um telefonema não pode rodar junto com o
     que já está decidido. Apagar aluno não tem desfazer. */
  const trava = g.classe === 'PROVAVEL' ? '-- ' : '';

  linhasSql.push(
    '',
    `-- ${g.classe}: ${g.fica.nome} — ${g.motivo}`,
    `-- fica:  ${g.fica.id}  (${data(g.fica.criado_em)}, ${(g.fica.acompanhantes || []).length} acomp., ${g.fica.codigo_curto})`,
    ...apagar.map(a =>
      `-- apaga: ${a.id}  (${data(a.criado_em)}, ${(a.acompanhantes || []).length} acomp., ${a.codigo_curto})`),
    ...(trava ? ['-- DESCOMENTE as duas linhas abaixo depois de confirmar com a família.'] : []),
    ...mudarDeDono.map(c =>
      `${trava}update public.acompanhantes set aluno_id = '${g.fica.id}' where id = '${c.id}';  -- ${c.nome}`),
    ...apagar.map(a => `${trava}delete from public.alunos where id = '${a.id}';`)
  );
}

/* ---------------------------------------------------------- */

const cabecalho = `-- ============================================================
-- Limpeza de inscrições duplicadas
-- Gerado por scripts/duplicatas.mjs em ${data(new Date().toISOString())}
--
-- LEIA ANTES DE RODAR. Cada bloco apaga uma inscrição, e delete
-- em alunos cascateia para acompanhantes, contatos salvos e log
-- de acesso (0008). Não tem desfazer.
--
-- Os UPDATE em acompanhantes vêm antes do DELETE de propósito:
-- eles salvam do cascade o acompanhante que só existia na linha
-- que vai sumir.
--
-- Os grupos marcados VERIFICAR não estão aqui: naqueles o script
-- não tem como saber se são duas pessoas ou uma.
--
-- Os marcados PROVAVEL estão, mas comentados. Ligue para a
-- família, confirme que é a mesma criança e só então descomente.
--
-- Rode dentro de uma transação, confira o que saiu, e só então
-- confirme:
--
--   begin;
--   ... os comandos abaixo ...
--   select nome, codigo_curto, ativo from public.alunos
--    where public.chave_nome(nome) in ('...');   -- confira
--   commit;   -- ou rollback; se algo parecer errado
-- ============================================================
`;

mkdirSync('saida', { recursive: true });
const arquivo = 'saida/duplicatas.sql';
writeFileSync(arquivo, cabecalho + linhasSql.join('\n') + '\n', 'utf8');

console.log('');
console.log('─'.repeat(78));
console.log(`${analisados.length} grupo(s) com nome repetido:`);
console.log(`  ${contagem.CERTA} duplicata(s) certa(s) — mesma pessoa, sem dúvida razoável`);
console.log(`  ${contagem.PROVAVEL} provável(is) — mesmo nome completo, contatos diferentes`);
console.log(`  ${contagem.VERIFICAR} a verificar — provável homônimo, o script não decide`);
console.log('');
console.log(`Roteiro de limpeza das ${contagem.CERTA + contagem.PROVAVEL} primeiras: ${arquivo}`);
console.log('Leia antes de rodar. Nada foi alterado no banco por este script.');
console.log('');
console.log('Resolva as duplicatas ANTES de gerar a leva de crachás: cada uma que');
console.log('escapar vira dois crachás com QRs diferentes para a mesma pessoa.');
