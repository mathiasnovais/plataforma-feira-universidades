/* ============================================================
   Geração dos crachás dos alunos
   Passo 7 da seção 13 dos requisitos.

   Lê os alunos no Supabase e escreve saida/crachas.html, pronto
   para imprimir pelo navegador (Ctrl+P > Salvar como PDF).

   Sem npm install. O QR é desenhado no navegador, em SVG, por
   uma biblioteca via CDN — então a máquina que abrir o arquivo
   precisa de internet.

   USO (PowerShell):
     node scripts/gerar-crachas.mjs https://SEU-DOMINIO

   A chave vem de segredo-supabase.txt (veja scripts/chave.mjs).

   O primeiro argumento é a URL onde o app estará publicado. Ela
   entra no QR, então precisa ser a URL DEFINITIVA — mudar de
   domínio depois obriga a reimprimir tudo.

   ---- LEVAS ----

   Aprovar não acontece de uma vez só: aprova um grupo, imprime,
   e semana que vem chega mais gente. Sem controle, a segunda
   geração traria de volta todo mundo da primeira e sairia crachá
   duplicado — dois papéis com o mesmo QR circulando no evento.

   Por isso a geração normal leva SÓ QUEM AINDA NÃO IMPRIMIU
   (`ativo = true` e `cracha_lote is null`) e carimba essa gente
   com o número da leva antes de escrever o arquivo. Quem foi
   carimbado nunca mais volta sozinho.

   Opções:
     (nenhuma)      a próxima leva: quem está na fila, e carimba
     --situacao     só mostra fila e levas já impressas, não gera
     --sem-marcar   gera a fila para conferir, SEM carimbar
     --lote 2       reimprime a leva 2 inteira (não carimba nada)
     --externos     todos os alunos de fora da Rede, de todas as levas
     --tudo         todos os ativos, ignorando as levas
     --desmarcar 2  devolve a leva 2 para a fila e sai
     --exemplo      6 crachás falsos, sem tocar no banco

     --unidade "Barra Olímpica"   a leva leva SÓ a fila dessa unidade
                                  (quem é de outra continua na fila)
     --arquivo extra-barra        troca o nome do arquivo:
                                  saida/crachas-extra-barra-alunos.html
     As duas combinam: uma leva por unidade, cada uma com seu
     arquivo, para as pilhas chegarem separadas em cada mesa.

   ATENÇÃO: os arquivos em saida/ contêm nome e token dos alunos.
   É dado pessoal de menor. Não publique essa pasta, não suba para
   o Cloudflare Pages e apague depois de imprimir.
   ============================================================ */

import { writeFileSync, mkdirSync } from 'node:fs';
import { CHAVE, exigirUrl } from './chave.mjs';

const URL_PROJETO = exigirUrl();
const argumentos = process.argv.slice(2);

/* --exemplo: gera 6 crachás falsos para conferir o layout e a
   impressão antes de existir aluno no banco. Não toca no Supabase. */
const EXEMPLO = argumentos.includes('--exemplo');
const SITUACAO = argumentos.includes('--situacao');
const TUDO = argumentos.includes('--tudo');
const SEM_MARCAR = argumentos.includes('--sem-marcar');
const EXTERNOS = argumentos.includes('--externos');
const URL_APP = (argumentos.find(a => a.startsWith('http')) || '').replace(/\/+$/, '');

/* Aceita `--lote 2` e `--lote=2`: um é o que a pessoa digita, o
   outro é o que ela copia de um exemplo. */
const numeroDe = nome => {
  const i = argumentos.findIndex(a => a === nome || a.startsWith(nome + '='));
  if (i < 0) return null;
  const bruto = argumentos[i].includes('=') ? argumentos[i].split('=')[1] : argumentos[i + 1];
  const n = Number(bruto);
  if (!Number.isInteger(n) || n < 1) {
    console.error(`${nome} precisa de um número de leva. Ex.: ${nome} 2`);
    console.error('Veja as levas existentes com --situacao.');
    process.exit(1);
  }
  return n;
};

const LOTE_PEDIDO = numeroDe('--lote');
const LOTE_DESMARCAR = numeroDe('--desmarcar');

/* Texto depois da opção, ex.: --unidade "Barra Olímpica". */
const textoDe = nome => {
  const i = argumentos.findIndex(a => a === nome || a.startsWith(nome + '='));
  if (i < 0) return null;
  const bruto = argumentos[i].includes('=')
    ? argumentos[i].slice(nome.length + 1)
    : argumentos[i + 1];
  const t = String(bruto || '').trim();
  if (!t) {
    console.error(`${nome} precisa de um valor. Ex.: ${nome} "Barra Olímpica"`);
    process.exit(1);
  }
  return t;
};

const UNIDADE = textoDe('--unidade');
const ARQUIVO = textoDe('--arquivo');
if (ARQUIVO && !/^[a-z0-9-]+$/i.test(ARQUIVO)) {
  console.error('--arquivo aceita só letras, números e hífen (vira nome de arquivo).');
  process.exit(1);
}

/* --situacao e --desmarcar não desenham QR nenhum, então não
   precisam da URL. Exigi-la ali só faria a pessoa procurar o
   domínio para perguntar quantos faltam. */
if (LOTE_DESMARCAR === null && !SITUACAO && !/^https?:\/\/.+/.test(URL_APP)) {
  console.error('Uso: node scripts/gerar-crachas.mjs https://SEU-DOMINIO [opções]');
  console.error('A URL entra no QR e precisa ser a definitiva.');
  console.error('Opções: --situacao --sem-marcar --lote N --externos --tudo --desmarcar N --exemplo');
  process.exit(1);
}
/* --exemplo não toca no banco, então roda sem chave nenhuma —
   serve justamente para conferir o layout numa máquina que não
   tem acesso ao Supabase. */
if (!CHAVE && !EXEMPLO) {
  console.error('Não achei a service_role.');
  console.error(`Crie o arquivo segredo-supabase.txt na pasta do projeto com a chave dentro.`);
  console.error('Supabase > Settings > API Keys > service_role > Reveal.');
  process.exit(1);
}

/* ---- conversa com o Supabase ---- */

const CAMPOS = 'id,nome,ano_escolaridade,unidade,colegio,aluno_alfacem,tipo,codigo_curto,cracha_token';

async function api(caminho, opcoes = {}) {
  const r = await fetch(`${URL_PROJETO}/rest/v1/${caminho}`, {
    ...opcoes,
    headers: {
      apikey: CHAVE,
      Authorization: 'Bearer ' + CHAVE,
      'Content-Type': 'application/json',
      ...(opcoes.headers || {})
    }
  });

  if (!r.ok) {
    const corpo = await r.text();
    /* silencioso: quem chamou sabe tratar a falha (tabela que pode
       não existir ainda). Todo o resto morre aqui mesmo. */
    if (opcoes.silencioso) return { erro: corpo };

    /* A coluna cracha_lote é da migration 0027. Sem ela nada aqui
       funciona, e o erro cru do PostgREST não diz o que fazer. */
    if (/cracha_lote/.test(corpo)) {
      console.error('O banco ainda não tem a coluna `cracha_lote`.');
      console.error('Rode a migration supabase/migrations/0027_lote_cracha.sql no SQL Editor.');
      process.exit(1);
    }
    console.error(`Falha na chamada ao Supabase (${caminho}):`);
    console.error(corpo);
    process.exit(1);
  }

  return r.status === 204 ? null : r.json();
}

/* Lista inteira, em páginas.

   O PostgREST tem teto de linhas por resposta e a resposta
   truncada não vem marcada como erro — vem como uma lista curta,
   igualzinha a uma lista curta de verdade. Com ~600 inscritos e
   ~900 acompanhantes estamos perto demais do teto usual (1000)
   para confiar na sorte: faltaria crachá e ninguém perceberia
   antes do dia do evento. */
async function apiTudo(caminho, opcoes = {}) {
  const PAGINA = 1000;
  const linhas = [];

  for (let de = 0; ; de += PAGINA) {
    const parte = await api(caminho, {
      ...opcoes,
      headers: { 'Range-Unit': 'items', Range: `${de}-${de + PAGINA - 1}`, ...(opcoes.headers || {}) }
    });
    if (parte && parte.erro) return parte;      // silencioso: devolve para quem chamou
    linhas.push(...parte);
    if (parte.length < PAGINA) return linhas;
  }
}

/* Ordem alfabética de gente: 'Ávila' vem antes de 'Bastos', e o
   sort padrão do JS põe depois de 'Zuza'. */
const porNome = new Intl.Collator('pt-BR').compare;
const ordenar = lista => lista.sort((a, b) => porNome(a.nome || '', b.nome || ''));

/* ---------------------------------------------------------- */
/* --situacao e --desmarcar resolvem e saem: nenhum dos dois
   gera arquivo. */

if (SITUACAO && !EXEMPLO) {
  const linhas = await apiTudo('alunos?select=cracha_lote,cracha_gerado_em&ativo=eq.true');
  const acomp = await apiTudo(
    'acompanhantes?select=alunos!inner(cracha_lote,ativo)&alunos.ativo=is.true');

  const levas = new Map();
  for (const l of linhas) {
    const chave = l.cracha_lote === null ? 'fila' : l.cracha_lote;
    const atual = levas.get(chave) || { pessoas: 0, acompanhantes: 0, em: l.cracha_gerado_em };
    atual.pessoas++;
    levas.set(chave, atual);
  }
  for (const c of acomp) {
    const chave = c.alunos.cracha_lote === null ? 'fila' : c.alunos.cracha_lote;
    if (levas.has(chave)) levas.get(chave).acompanhantes++;
  }

  const ordem = [...levas.keys()].sort((a, b) =>
    a === 'fila' ? 1 : b === 'fila' ? -1 : a - b);

  if (!ordem.length) {
    console.log('Nenhum inscrito ativo ainda.');
  } else {
    console.log('LEVA        INSCRITOS  ACOMPANHANTES  CRACHÁS  GERADA EM');
    for (const k of ordem) {
      const v = levas.get(k);
      const rotulo = k === 'fila' ? 'na fila' : 'leva ' + k;
      const data = k === 'fila' ? '—'
        : new Date(v.em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' });
      console.log(
        rotulo.padEnd(12) +
        String(v.pessoas).padStart(9) +
        String(v.acompanhantes).padStart(15) +
        String(v.pessoas + v.acompanhantes).padStart(9) +
        '  ' + data);
    }
  }

  const fila = levas.get('fila');
  console.log(fila
    ? `\n${fila.pessoas + fila.acompanhantes} crachá(s) esperando. Gere com o comando sem opções.`
    : '\nFila vazia: todo mundo que está ativo já teve crachá gerado.');
  process.exit(0);
}

if (LOTE_DESMARCAR !== null) {
  const devolvidos = await apiTudo(`alunos?select=nome&cracha_lote=eq.${LOTE_DESMARCAR}`);

  await api(`alunos?cracha_lote=eq.${LOTE_DESMARCAR}`, {
    method: 'PATCH',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({ cracha_lote: null, cracha_gerado_em: null })
  });

  if (!devolvidos.length) {
    console.log(`Leva ${LOTE_DESMARCAR} não existe ou já foi devolvida. Nada mudou.`);
  } else {
    console.log(`${devolvidos.length} inscrito(s) da leva ${LOTE_DESMARCAR} voltaram para a fila.`);
    console.log('Os acompanhantes deles vão junto — eles herdam a leva do aluno.');
    console.log('Apague o arquivo dessa leva em saida/ para não imprimir por engano.');
  }
  process.exit(0);
}

/* ---------------------------------------------------------- */

let alunos;
let lote = null;          // número da leva, quando há uma
let filtroAcomp = '';     // como achar os acompanhantes dessa mesma gente
let base = 'saida/crachas';  // prefixo dos arquivos; a categoria completa o nome
let rotulo = '';          // o que aparece no topo do HTML e no console

if (EXEMPLO) {
  alunos = [
    { nome: 'Ana Ribeiro', ano_escolaridade: '3ª Série do Ensino Médio', unidade: 'Barra Américas',  aluno_alfacem: true,  codigo_curto: 'K7M2QX', cracha_token: 'a'.repeat(32) },
    { nome: 'Bruno Costa', ano_escolaridade: '2ª Série do Ensino Médio', unidade: 'Freguesia - Jacarepaguá', aluno_alfacem: true, codigo_curto: 'P4TJ9N', cracha_token: 'b'.repeat(32) },
    { nome: 'Carla Dias',  ano_escolaridade: '9º ano do Ensino Fundamental', colegio: 'Colégio Externo', aluno_alfacem: false, codigo_curto: 'W3HD6R', cracha_token: 'c'.repeat(32) },
    { nome: 'Diego Alves', ano_escolaridade: '1ª Série do Ensino Médio', unidade: 'Barra Olímpica', aluno_alfacem: true, codigo_curto: 'Z9FB5L', cracha_token: 'd'.repeat(32) },
    { nome: 'Mariana Costa', tipo: 'counselor', colegio: 'Colégio Sant Anna', aluno_alfacem: false, codigo_curto: 'Q8XN4V', cracha_token: 'e'.repeat(32) },
    { nome: 'Rafael Menezes', tipo: 'docente', unidade: 'Tijuca', aluno_alfacem: true, codigo_curto: 'H2LC7T', cracha_token: 'f'.repeat(32) }
  ];
  base = 'saida/crachas-exemplo';
  rotulo = 'exemplo';
  console.log('Modo exemplo: 6 crachás falsos, sem consultar o Supabase.');

} else if (TUDO) {
  /* Reimpressão geral: ignora as levas e traz todo mundo. Não
     carimba nada — quem já imprimiu continua marcado na leva
     dele. Serve para trocar de domínio, quando o QR antigo morre
     e tudo precisa sair de novo. */
  alunos = ordenar(await apiTudo(`alunos?select=${CAMPOS}&ativo=eq.true`));
  filtroAcomp = '';
  base = 'saida/crachas-todos';
  rotulo = 'todos os ativos';
  console.log('Modo --tudo: TODOS os ativos, inclusive quem já imprimiu.');
  console.log('Nada foi carimbado. Não imprima isto por cima de leva já entregue.\n');

} else if (EXTERNOS) {
  /* Todos os alunos de fora da Rede, tenham sido impressos ou
     não. Serve para mandar essa pilha à gráfica separada, sem
     mexer nas levas: quem já saiu continua carimbado, e a próxima
     leva não traz ninguém de volta.

     `tipo = aluno` é necessário: counselor também tem
     aluno_alfacem = false — ele vem de outra instituição por
     definição — e não é aluno externo. */
  alunos = ordenar(await apiTudo(
    `alunos?select=${CAMPOS}&ativo=eq.true&aluno_alfacem=is.false&tipo=eq.aluno`));

  if (!alunos.length) {
    console.error('Nenhum aluno externo ativo. Confira com --situacao.');
    process.exit(1);
  }

  filtroAcomp = '&alunos.aluno_alfacem=is.false&alunos.tipo=eq.aluno';
  base = 'saida/crachas-externos';
  rotulo = 'todos os alunos externos';
  console.log('Modo --externos: todos os alunos de fora da Rede, de todas as levas.');
  console.log('Nada foi carimbado — as levas continuam como estão.\n');

} else if (LOTE_PEDIDO !== null) {
  /* Reimpressão de uma leva: mesma gente, mesmo arquivo. O papel
     molhou, a gráfica perdeu, a impressora comeu meia folha. */
  alunos = ordenar(await apiTudo(
    `alunos?select=${CAMPOS}&ativo=eq.true&cracha_lote=eq.${LOTE_PEDIDO}`));

  if (!alunos.length) {
    console.error(`A leva ${LOTE_PEDIDO} não tem ninguém ativo. Veja as levas com --situacao.`);
    process.exit(1);
  }

  lote = LOTE_PEDIDO;
  filtroAcomp = `&alunos.cracha_lote=eq.${LOTE_PEDIDO}`;
  base = `saida/crachas-leva-${String(LOTE_PEDIDO).padStart(3, '0')}`;
  rotulo = `leva ${LOTE_PEDIDO} (reimpressão)`;
  console.log(`Reimprimindo a leva ${LOTE_PEDIDO}. Nada foi carimbado de novo.`);

} else if (SEM_MARCAR) {
  /* A fila como está, sem carimbar. É a conferência antes de
     valer: dá para abrir, contar e conversar com a secretaria
     sem que ninguém saia da fila. */
  alunos = ordenar(await apiTudo(`alunos?select=${CAMPOS}&ativo=eq.true&cracha_lote=is.null`));

  if (!alunos.length) {
    console.error('A fila está vazia: todo mundo ativo já teve crachá gerado.');
    process.exit(1);
  }

  filtroAcomp = '&alunos.cracha_lote=is.null';
  base = 'saida/crachas-fila';
  rotulo = 'fila, ainda sem carimbo';
  console.log('Modo --sem-marcar: ninguém saiu da fila.');
  console.log('Este arquivo é para CONFERIR. Se imprimir sem carimbar, a próxima');
  console.log('leva traz essa gente de volta e sai duplicado.\n');

} else {
  /* ---- a leva de verdade ----

     O carimbo vem ANTES de montar o arquivo, e é ele que decide
     quem entra: um único UPDATE marca a fila inteira e devolve
     exatamente as linhas que marcou.

     Ao contrário de ler primeiro e marcar depois, aqui não existe
     a brecha de alguém ser aprovado no meio do caminho e sair
     carimbado sem estar no arquivo — o que faria o crachá dessa
     pessoa nunca ser impresso, sem ninguém perceber.

     A leitura vem depois, filtrando pela leva recém-criada: como
     o número é novo, ela devolve exatamente quem o UPDATE pegou. */
  const ultima = await api(
    'alunos?select=cracha_lote&cracha_lote=not.is.null&order=cracha_lote.desc&limit=1');
  lote = ((ultima[0] && ultima[0].cracha_lote) || 0) + 1;

  /* --unidade restringe o carimbo: só a fila daquela unidade entra
     na leva; o resto da fila fica onde está, para a leva seguinte.
     O filtro vai no MESMO update que carimba — ler primeiro e
     carimbar depois abriria a brecha descrita acima. */
  const filtroUnidade = UNIDADE ? `&unidade=eq.${encodeURIComponent(UNIDADE)}` : '';

  await api(`alunos?ativo=eq.true&cracha_lote=is.null${filtroUnidade}`, {
    method: 'PATCH',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({ cracha_lote: lote, cracha_gerado_em: new Date().toISOString() })
  });

  alunos = ordenar(await apiTudo(`alunos?select=${CAMPOS}&cracha_lote=eq.${lote}`));

  if (!alunos.length) {
    if (UNIDADE) {
      console.error(`Ninguém na fila da unidade "${UNIDADE}".`);
      console.error('Confira a grafia (tem que ser idêntica à coluna unidade) e a fila com --situacao.');
    } else {
      console.error('Ninguém na fila: todo mundo ativo já teve crachá gerado.');
      console.error('Aprove as inscrições pendentes (docs/inscricoes.md) e rode de novo,');
      console.error(`ou reimprima uma leva com --lote N. Situação atual: --situacao.`);
    }
    process.exit(1);
  }

  filtroAcomp = `&alunos.cracha_lote=eq.${lote}`;
  base = `saida/crachas-leva-${String(lote).padStart(3, '0')}`;
  rotulo = `leva ${lote}` + (UNIDADE ? ` · ${UNIDADE}` : '');
  console.log(`Leva ${lote}${UNIDADE ? ' (só ' + UNIDADE + ')' : ''}: ${alunos.length} inscrito(s) carimbado(s) e fora da fila.\n`);
}

/* --arquivo troca o prefixo da saída em qualquer modo; a categoria
   (-alunos, -responsaveis…) continua completando o nome. */
if (ARQUIVO) base = `saida/crachas-${ARQUIVO}`;

/* ---- acompanhantes ----

   Quem entra no evento precisa de crachá, e não é só o aluno. O
   crachá do acompanhante carrega o cracha_token DO ALUNO: quem
   escanear a mãe abre o perfil do filho. Acompanhante não tem
   token próprio porque não tem perfil próprio (migration 0012).

   Só entram os de aluno ativo. Aluno reprovado na revisão não
   imprime crachá, e os acompanhantes dele também não.

   Acompanhante também não tem leva própria: `filtroAcomp` amarra
   a busca à mesma leva dos alunos que acabaram de sair. Sem isso
   a leva 2 sairia com os acompanhantes da leva 1 junto. */

if (EXEMPLO) {
  alunos[0].acompanhantes = [
    { nome: 'Helena Ribeiro', parentesco: 'Mãe' },
    { nome: 'Paulo Ribeiro',  parentesco: 'Pai' }
  ];
  alunos[2].acompanhantes = [{ nome: 'Sônia Dias', parentesco: 'Avó / Avô' }];
} else {
  const lista = await apiTudo(
    'acompanhantes' +
    '?select=nome,parentesco,alunos!inner(nome,cracha_token,codigo_curto,ativo)' +
    `&alunos.ativo=is.true${filtroAcomp}&order=nome`,
    { silencioso: true }
  );

  if (lista.erro) {
    /* Erro de tabela inexistente é o caso comum: a 0012 não foi
       rodada. Vale avisar em vez de derrubar — os crachás dos
       alunos continuam saindo. */
    if (/acompanhantes/i.test(lista.erro) && /(does not exist|relation)/i.test(lista.erro)) {
      console.warn('AVISO: tabela `acompanhantes` não existe. Rode a migration 0012.');
      console.warn('       Os crachás dos alunos saem; os dos acompanhantes, não.\n');
    } else {
      console.error('Falha ao ler acompanhantes:', lista.erro);
      process.exit(1);
    }
  } else {
    for (const c of lista) {
      const a = alunos.find(x => x.cracha_token === c.alunos.cracha_token);
      if (!a) continue;   // aluno fora da lista de ativos
      (a.acompanhantes = a.acompanhantes || []).push(c);
    }
  }
}

const semNome = alunos.filter(a => !a.nome || !a.nome.trim());
if (semNome.length) console.warn(`${semNome.length} aluno(s) sem nome — o crachá sai em branco.`);

/* ---------------------------------------------------------- */

const escapar = t => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;');

/* Subtítulo do crachá: ano de escolaridade e de onde o aluno vem.
   É o que o representante de universidade usa para se situar antes
   mesmo de escanear — série define elegibilidade de admissão.

   College Counselor não tem série nem unidade: o que o situa é a
   instituição de onde vem, guardada em `colegio` (migration 0014). */
const escola = a => a.tipo === 'counselor' || a.tipo === 'docente'
  ? (a.colegio || a.unidade || 'Instituição não informada')
  : a.aluno_alfacem === false
    ? (a.colegio || 'Colégio externo')
    : (a.unidade || 'Rede Alfacem Global Academy');

const subtitulo = a =>
    a.tipo === 'counselor' ? 'College Counselor · ' + escola(a)
  : a.tipo === 'docente'   ? 'Docente · ' + escola(a)
  : [a.ano_escolaridade, escola(a)].filter(Boolean).join(' · ');

/* ---- uma pessoa, um crachá ----

   Aluno, counselor, docente e acompanhante viram todos o mesmo
   objeto aqui. `grupo` é o que decide em qual arquivo a pessoa
   sai; o resto do código não precisa saber de onde ela veio.

   O acompanhante continua carregando o token E o código curto DO
   ALUNO: quem escanear a mãe abre o perfil do filho. Ele não tem
   perfil próprio (0012). */
/* Aluno externo tem arquivo próprio.

   Não é um `tipo` no banco — é um aluno com aluno_alfacem =
   false. Mas na gráfica e na mesa ele é outra pilha: chega por
   outro caminho, muitas vezes em lote fechado com o colégio de
   origem, e às vezes precisa ser enviado para impressão separado
   do resto. Misturado com os 700 da Rede, achar os 12 externos
   vira trabalho manual. */
const grupoDe = a =>
    a.tipo === 'counselor'  ? 'counselors'
  : a.tipo === 'docente'    ? 'docentes'
  : a.aluno_alfacem === false ? 'externos'
  : 'alunos';

/* O responsável leva a palavra "Responsável" e, em seguida, o
   MESMO subtítulo do aluno: série e unidade. Sem a palavra, o
   crachá dele ficava idêntico ao de um aluno da mesma turma, e na
   entrada não dava para saber quem é adulto sem escanear.

   O parentesco ("Mãe", "Pai", "Avó / Avô") não vai para o papel,
   nem o nome do aluno.

   O que amarra os dois continua sendo o código curto impresso
   embaixo, que é o do aluno, e o QR, que abre o perfil dele. Na
   mesa de entrada é por ali que se confere, não pelo texto.

   O parentesco continua no banco, para a lista de presença. */
const pessoas = alunos.flatMap(a => [
  {
    grupo: grupoDe(a),
    nome: a.nome,
    sub: subtitulo(a),
    token: a.cracha_token,
    codigo: a.codigo_curto
  },
  ...(a.acompanhantes || []).map(c => ({
    grupo: 'responsaveis',
    nome: c.nome,
    sub: 'Responsável · ' + subtitulo(a),
    token: a.cracha_token,
    codigo: a.codigo_curto
  }))
]);

/* A ordem é a de quem vai recortar as folhas: primeiro os alunos,
   depois os responsáveis. Dentro de cada arquivo a ordem alfabética
   dos alunos é preservada, então achar uma pessoa é folhear. */
const GRUPOS = [
  { chave: 'alunos',        titulo: 'Alunos da Rede' },
  { chave: 'externos',      titulo: 'Alunos externos' },
  { chave: 'responsaveis',  titulo: 'Responsáveis' },
  { chave: 'counselors',    titulo: 'College Counselors' },
  { chave: 'docentes',      titulo: 'Docentes' }
];

const cartao = p => `
    <div class="cracha">
      <div class="info">
        <p class="nome">${escapar(p.nome)}</p>
        <p class="turma">${escapar(p.sub)}</p>
        <div class="rodape">
          <span class="rotulo">código</span>
          <span class="codigo">${escapar(p.codigo)}</span>
        </div>
      </div>
      <div class="qr" data-url="${escapar(URL_APP)}/#/p/${escapar(p.token)}"></div>
    </div>`;

/* Uma folha de crachás por categoria. A página é a mesma; muda
   quem está dentro dela, o título e o nome dos arquivos que os
   botões de exportar baixam — dois ZIPs com o mesmo nome na pasta
   de Downloads seria o jeito mais fácil de misturar tudo de novo
   depois de separar. */
const montarHtml = (lista, titulo, apelido) => {

/* Os mesmos crachás em dados, para a exportação em PNG desenhar
   no canvas. O HTML serve à impressão pelo navegador; o canvas
   serve à gráfica que só aceita imagem.

   JSON.stringify não escapa `<`, e um nome com "<" fecharia a tag
   <script> que envolve isto. */
const dadosJson = JSON.stringify(lista).replace(/</g, '\\u003c');
const cartoes = lista.map(cartao).join('');

return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>${escapar(titulo)}${rotulo ? ' — ' + escapar(rotulo) : ''} — ${lista.length} crachás</title>
<script src="https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js"><\/script>
<style>
  @page { size: A4; margin: 8mm; }

  * { box-sizing: border-box; }
  body {
    margin: 0; background: #e9ecf1;
    font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: #14181f;
  }

  .instrucoes {
    max-width: 190mm; margin: 16px auto; padding: 16px 20px;
    background: #fff4d6; color: #8a5a00; border-radius: 10px; line-height: 1.5;
  }
  .instrucoes b { color: #6b4600; }

  /* 80 x 40mm por crachá. A4 útil (194 x 281mm, com a margem de
     8mm do @page) comporta 2 colunas e 7 linhas: 14 por folha. */
  .folha {
    width: 160mm; margin: 0 auto; background: #fff;
    display: grid; grid-template-columns: repeat(2, 80mm);
    gap: 0;
  }

  .cracha {
    width: 80mm; height: 40mm;
    padding: 3mm;
    border: 1px dashed #b8bfc9;   /* guia de corte */
    display: flex; flex-direction: row; align-items: center; gap: 2mm;
    break-inside: avoid; page-break-inside: avoid;
  }

  /* Texto à esquerda, QR à direita. min-width:0 é o que permite
     o nome quebrar em vez de empurrar o QR para fora do crachá —
     item de flex não encolhe abaixo do conteúdo sem isso. */
  .info   { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1mm; }
  .nome   { font-size: 11.5pt; font-weight: 700; margin: 0; line-height: 1.15;
            overflow-wrap: anywhere; }
  .turma  { font-size: 8pt; color: #4a5361; margin: 0; line-height: 1.25;
            overflow-wrap: anywhere; }

  .rodape { display: flex; align-items: baseline; gap: 1.5mm; margin-top: .5mm; }
  .rotulo { font-size: 5.5pt; letter-spacing: .16em; text-transform: uppercase; color: #6b7482; }
  .codigo { font-size: 11pt; font-weight: 700; letter-spacing: .12em;
            font-family: ui-monospace, "Cascadia Mono", Consolas, monospace; }

  .qr     { width: 34mm; height: 34mm; flex: none;
            display: flex; align-items: center; justify-content: center; }
  .qr svg { width: 100%; height: 100%; }

  .exportar {
    max-width: 190mm; margin: 16px auto; padding: 16px 20px;
    background: #fff; border: 1px solid #ccd3dc; border-radius: 10px; line-height: 1.5;
  }
  .exportar .linha { display: flex; flex-wrap: wrap; gap: 14px; align-items: flex-end; margin-top: 12px; }
  .exportar label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: #5a6474; }
  .exportar select { padding: 7px 9px; font: inherit; font-size: 13px; }
  .exportar button {
    padding: 9px 18px; font: inherit; font-size: 13px; font-weight: 600;
    background: #14181f; color: #fff; border: 0; border-radius: 6px; cursor: pointer;
  }
  .exportar button:disabled { background: #9aa3af; cursor: default; }
  .exportar button.secundario { background: #fff; color: #14181f; border: 1px solid #ccd3dc; }
  .progresso { margin: 12px 0 0; font-size: 13px; color: #5a6474; min-height: 1.2em; }

  @media print {
    body { background: #fff; }
    .instrucoes, .exportar { display: none; }
    .folha { width: auto; margin: 0; }
    .cracha { border-color: #d0d5dc; }
  }
</style>
</head>
<body>

<div class="instrucoes">
  <p><b>${escapar(titulo)}: ${lista.length} crachás</b>${lote ? `, <b>leva ${lote}</b>` : ''}.
  Este arquivo tem <b>só esta categoria</b> — as outras saíram em arquivos separados,
  na mesma pasta. Imprima com <b>Ctrl+P</b> → Salvar como PDF.
  Nas opções, marque <b>"Gráficos de fundo"</b> e deixe a escala em <b>100%</b> —
  reduzir a escala encolhe o QR e prejudica a leitura no papel.</p>
  <p>As linhas tracejadas são guia de corte e somem na impressão em papel comum.</p>
  ${SEM_MARCAR ? `<p><b>Esta é a fila, ainda sem carimbo.</b> Ninguém aqui saiu da fila:
  se você imprimir este arquivo, essa mesma gente volta na próxima leva e sai crachá
  duplicado. Para valer, gere de novo sem <b>--sem-marcar</b>.</p>` : ''}
  ${TUDO ? `<p><b>Este arquivo tem todos os ativos</b>, inclusive quem já recebeu crachá
  em levas anteriores. Só imprima se a intenção for reemitir tudo.</p>` : ''}
  <p><b>Este arquivo contém nome e token de todos os alunos.</b> É dado pessoal de
  menor de idade: não publique, não suba para a hospedagem e apague depois de imprimir.</p>
</div>

<div class="exportar">
  <p><b>Gráfica só aceita imagem?</b> Gere PNG aqui mesmo — nada sai do seu computador.
  Para impressão, o PDF acima continua sendo melhor: nele o QR é vetor e sai com borda
  perfeita em qualquer tamanho.</p>
  <div class="linha">
    <label>Formato
      <select id="modo">
        <option value="folha">14 crachás por folha A4 (2 x 7)</option>
        <option value="ampliado">1 crachá por folha A4 (ampliado)</option>
        <option value="cracha">Um arquivo por crachá (80 x 40mm)</option>
      </select>
    </label>
    <label>Resolução
      <select id="dpi">
        <option value="300">300 DPI — qualidade de gráfica</option>
        <option value="200">200 DPI — arquivo menor</option>
        <option value="150">150 DPI — só para conferir</option>
      </select>
    </label>
    <button id="btn-pdf" type="button">Gerar PDF</button>
    <button id="btn-png" type="button" class="secundario">Gerar ZIP de PNG</button>
  </div>
  <p id="progresso" class="progresso"></p>
</div>

<div class="folha">${cartoes}
</div>

<script>
  /* Nível de correção de erro Q: recupera ~25% do código danificado.
     Crachá amassado, com reflexo ou dobrado é risco alto conhecido
     deste projeto — o código curto impresso abaixo é o segundo
     fallback, mas quanto mais o QR aguentar, menos gente digita. */
  document.querySelectorAll('.qr').forEach(function (el) {
    var qr = qrcode(0, 'Q');
    qr.addData(el.dataset.url);
    qr.make();
    el.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 0, scalable: true });
  });

  /* ============================================================
     Exportação em PNG

     Cada crachá é DESENHADO no canvas a partir dos dados, e não
     capturado da tela. Ferramenta de captura (html2canvas e afins)
     rasteriza SVG de forma inconsistente entre navegadores — e o
     QR é justamente um SVG. Um QR com borda mole é um QR que a
     câmera não lê sob a luz do evento.

     Desenhando os módulos direto, cada quadradinho cai em pixel
     inteiro e sai perfeito em qualquer resolução.
     ============================================================ */
  var DADOS = ${dadosJson};
  var URL_APP = ${JSON.stringify(URL_APP)};
  var APELIDO = ${JSON.stringify(apelido)};

  var mm = function (v, dpi) { return v / 25.4 * dpi; };
  var pt = function (v, dpi) { return v / 72 * dpi; };

  /* Canvas não tem letter-spacing em navegador antigo, e o código
     curto depende dele para ser legível. Desenhado caractere a
     caractere, funciona em todos. */
  function textoEspacado(ctx, texto, cx, y, espaco) {
    var larguras = [], total = 0;
    for (var i = 0; i < texto.length; i++) {
      var w = ctx.measureText(texto[i]).width;
      larguras.push(w);
      total += w + (i < texto.length - 1 ? espaco : 0);
    }
    var x = cx - total / 2;
    for (var j = 0; j < texto.length; j++) {
      ctx.fillText(texto[j], x, y);
      x += larguras[j] + espaco;
    }
  }

  function quebrar(ctx, texto, largura) {
    var palavras = String(texto || '').split(/\\s+/), linhas = [], atual = '';
    for (var i = 0; i < palavras.length; i++) {
      var teste = atual ? atual + ' ' + palavras[i] : palavras[i];
      if (ctx.measureText(teste).width > largura && atual) { linhas.push(atual); atual = palavras[i]; }
      else atual = teste;
    }
    if (atual) linhas.push(atual);
    return linhas;
  }

  /* Reproduz o .cracha do CSS: 80x40mm, padding 3mm, texto à
     esquerda e QR à direita.

     As medidas estão duplicadas aqui e no CSS de propósito: são
     dois motores de desenho diferentes (navegador imprimindo e
     canvas exportando) e não há como um ler o outro. Mexeu numa,
     mexa na outra — o teste no fim do arquivo compara as duas. */
  var CRACHA = { larg: 80, alt: 40, pad: 3, qr: 34, gap: 2 };

  function desenharCracha(ctx, d, x0, y0, dpi) {
    var L = mm(CRACHA.larg, dpi), A = mm(CRACHA.alt, dpi);
    var pad = mm(CRACHA.pad, dpi);
    var ladoQR = mm(CRACHA.qr, dpi);
    var util = L - pad * 2 - ladoQR - mm(CRACHA.gap, dpi);

    ctx.save();
    ctx.translate(x0, y0);

    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, L, A);

    ctx.strokeStyle = '#d0d5dc';
    ctx.lineWidth = Math.max(1, dpi / 300);
    ctx.setLineDash([mm(1.5, dpi), mm(1.5, dpi)]);
    ctx.strokeRect(0, 0, L, A);
    ctx.setLineDash([]);

    /* ---- coluna da esquerda ----
       Medida antes de desenhar, para centralizar verticalmente o
       bloco inteiro: nome de uma linha e de duas ficam os dois
       alinhados com o QR. */
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';

    var fNome = pt(11.5, dpi), fSub = pt(8, dpi), fCod = pt(11, dpi), fRot = pt(5.5, dpi);
    var lhNome = fNome * 1.15, lhSub = fSub * 1.25;

    /* Três linhas, não duas: com o nome em 11,5pt "Maria Eduarda
       Rocha de Oliveira" não cabe em duas, e cortar sobrenome no
       crachá é pior do que ocupar mais uma linha. Cabe — o bloco
       inteiro dá ~27mm nos 34mm úteis de altura. */
    ctx.font = '700 ' + fNome + 'px -apple-system, "Segoe UI", Roboto, sans-serif';
    var linhas = quebrar(ctx, d.nome, util).slice(0, 3);

    /* Também três: "Responsável · 9º ano do Ensino Fundamental ·
       Freguesia - Jacarepaguá" passa de duas linhas em 8pt, e
       cortar deixaria o crachá sem a unidade. Nome e subtítulo
       nos dois piores casos somam ~31mm dos 34mm úteis. */
    ctx.font = fSub + 'px -apple-system, "Segoe UI", Roboto, sans-serif';
    var subs = quebrar(ctx, d.sub, util).slice(0, 3);

    var altura = linhas.length * lhNome + mm(1, dpi)
               + subs.length * lhSub + mm(1.5, dpi) + fCod;
    var y = Math.max(pad, (A - altura) / 2);

    ctx.fillStyle = '#14181f';
    ctx.font = '700 ' + fNome + 'px -apple-system, "Segoe UI", Roboto, sans-serif';
    for (var i = 0; i < linhas.length; i++) { ctx.fillText(linhas[i], pad, y); y += lhNome; }

    y += mm(1, dpi);
    ctx.fillStyle = '#4a5361';
    ctx.font = fSub + 'px -apple-system, "Segoe UI", Roboto, sans-serif';
    for (var k = 0; k < subs.length; k++) { ctx.fillText(subs[k], pad, y); y += lhSub; }

    /* código, com o rótulo à esquerda dele, na mesma linha de base */
    y += mm(1.5, dpi);
    ctx.textBaseline = 'alphabetic';
    var base = y + fCod * 0.8;

    ctx.fillStyle = '#6b7482';
    ctx.font = fRot + 'px -apple-system, "Segoe UI", Roboto, sans-serif';
    var rotulo = 'CÓDIGO ';
    ctx.fillText(rotulo, pad, base);
    var larguraRotulo = ctx.measureText(rotulo).width + fRot * 0.16 * rotulo.length;

    ctx.fillStyle = '#14181f';
    ctx.font = '700 ' + fCod + 'px ui-monospace, Consolas, monospace';
    var xCod = pad + larguraRotulo + mm(1, dpi);
    var esp = fCod * 0.12;
    for (var c2 = 0; c2 < d.codigo.length; c2++) {
      ctx.fillText(d.codigo[c2], xCod, base);
      xCod += ctx.measureText(d.codigo[c2]).width + esp;
    }

    /* ---- QR à direita, centralizado na altura ---- */
    var qr = qrcode(0, 'Q');
    qr.addData(URL_APP + '/#/p/' + d.token);
    qr.make();
    var n = qr.getModuleCount();
    var passo = ladoQR / n;
    var qx = L - pad - ladoQR, qy = (A - ladoQR) / 2;
    ctx.fillStyle = '#000';
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (!qr.isDark(r, c)) continue;
        // Math.ceil evita fresta branca entre módulos vizinhos
        ctx.fillRect(Math.round(qx + c * passo), Math.round(qy + r * passo),
                     Math.ceil(passo), Math.ceil(passo));
      }
    }

    ctx.restore();
  }

  /* ============================================================
     PDF em vetor

     Não é a folha capturada como imagem: o texto vai como texto e
     o QR como retângulos. Isso importa na impressão — vetor sai
     com borda exata em qualquer ampliação, e um QR de borda mole
     é um QR que a câmera não lê sob a luz do evento.

     De quebra o arquivo fica pequeno e a gráfica consegue abrir
     sem esperar.
     ============================================================ */
  function carregarScript(url) {
    return new Promise(function (ok, erro) {
      var s = document.createElement('script');
      s.src = url;
      s.onload = ok;
      s.onerror = function () { erro(new Error('sem internet para baixar a biblioteca')); };
      document.head.appendChild(s);
    });
  }

  /* Módulos escuros vizinhos na mesma linha viram um retângulo só.
     Um QR tem ~1600 módulos; sem juntar, 229 crachás dariam mais
     de 200 mil retângulos e o PDF ficaria pesado e lento de abrir.
     Juntando, cai para perto de um terço disso. */
  function faixasDoQR(qr) {
    var n = qr.getModuleCount(), faixas = [];
    for (var r = 0; r < n; r++) {
      var ini = -1;
      for (var c = 0; c <= n; c++) {
        var escuro = c < n && qr.isDark(r, c);
        if (escuro && ini < 0) ini = c;
        if (!escuro && ini >= 0) { faixas.push([ini, r, c - ini]); ini = -1; }
      }
    }
    return { n: n, faixas: faixas };
  }

  function crachaNoPdf(doc, d, x0, y0, escala) {
    var e = escala || 1;
    var L = CRACHA.larg * e, A = CRACHA.alt * e;
    var pad = CRACHA.pad * e, ladoQR = CRACHA.qr * e;
    var util = L - pad * 2 - ladoQR - CRACHA.gap * e;

    // guia de corte
    doc.setDrawColor(200, 208, 220);
    doc.setLineWidth(0.1);
    doc.rect(x0, y0, L, A);

    /* Alturas em mm: pt / 72 * 25.4. jsPDF mede fonte em pt e
       posiciona em mm, então a conversão fica explícita. */
    var mmPt = function (p) { return p / 72 * 25.4; };
    var fNome = 11.5 * e, fSub = 8 * e, fCod = 11 * e, fRot = 5.5 * e;

    doc.setFont('helvetica', 'bold');
    doc.setFontSize(fNome);
    var linhas = doc.splitTextToSize(String(d.nome || ''), util).slice(0, 3);

    doc.setFont('helvetica', 'normal');
    doc.setFontSize(fSub);
    var subs = doc.splitTextToSize(String(d.sub || ''), util).slice(0, 3);

    var hNome = linhas.length * mmPt(fNome) * 1.15;
    var hSub  = subs.length * mmPt(fSub) * 1.25;
    var total = hNome + 1 * e + hSub + 1.5 * e + mmPt(fCod);
    var y = y0 + Math.max(pad, (A - total) / 2) + mmPt(fNome) * 0.85;

    doc.setFont('helvetica', 'bold');
    doc.setFontSize(fNome);
    doc.setTextColor(20, 24, 31);
    for (var i = 0; i < linhas.length; i++) {
      doc.text(linhas[i], x0 + pad, y);
      y += mmPt(fNome) * 1.15;
    }

    y += 1 * e;
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(fSub);
    doc.setTextColor(74, 83, 97);
    for (var k = 0; k < subs.length; k++) {
      doc.text(subs[k], x0 + pad, y);
      y += mmPt(fSub) * 1.25;
    }

    y += 1.5 * e;
    doc.setFontSize(fRot);
    doc.setTextColor(107, 116, 130);
    doc.text('CÓDIGO', x0 + pad, y);
    var larguraRotulo = doc.getTextWidth('CÓDIGO');

    doc.setFont('courier', 'bold');
    doc.setFontSize(fCod);
    doc.setTextColor(20, 24, 31);
    doc.text(String(d.codigo || ''), x0 + pad + larguraRotulo + 1.5 * e, y);

    // QR
    var qr = qrcode(0, 'Q');
    qr.addData(URL_APP + '/#/p/' + d.token);
    qr.make();
    var m = faixasDoQR(qr);
    var passo = ladoQR / m.n;
    var qx = x0 + L - pad - ladoQR, qy = y0 + (A - ladoQR) / 2;
    doc.setFillColor(0, 0, 0);
    for (var j = 0; j < m.faixas.length; j++) {
      var fx = m.faixas[j];
      doc.rect(qx + fx[0] * passo, qy + fx[1] * passo, fx[2] * passo, passo, 'F');
    }
  }

  document.getElementById('btn-pdf').addEventListener('click', async function () {
    var btn = this, aviso = document.getElementById('progresso');
    var modo = document.getElementById('modo').value;
    btn.disabled = true;

    try {
      if (!window.jspdf) {
        aviso.textContent = 'Carregando a biblioteca de PDF…';
        await carregarScript('https://cdn.jsdelivr.net/npm/jspdf@2.5.1/dist/jspdf.umd.min.js');
      }
      var jsPDF = window.jspdf.jsPDF;

      var COLS = 2, LINS = 7;
      var doc, porPagina, escala = 1;

      if (modo === 'cracha') {
        // Uma página do tamanho exato do crachá.
        doc = new jsPDF({ unit: 'mm', format: [CRACHA.larg, CRACHA.alt] });
        porPagina = 1;
      } else if (modo === 'ampliado') {
        doc = new jsPDF({ unit: 'mm', format: 'a4' });
        porPagina = 1;
        escala = 194 / CRACHA.larg;
      } else {
        doc = new jsPDF({ unit: 'mm', format: 'a4' });
        porPagina = COLS * LINS;
      }

      var margemX = modo === 'cracha' ? 0 : (210 - CRACHA.larg * (modo === 'folha' ? COLS : escala)) / 2;
      var margemY = modo === 'cracha' ? 0
                  : modo === 'ampliado' ? (297 - CRACHA.alt * escala) / 2
                  : (297 - CRACHA.alt * LINS) / 2;

      for (var i = 0; i < DADOS.length; i++) {
        var pos = i % porPagina;
        if (i > 0 && pos === 0) doc.addPage();

        var col = modo === 'folha' ? pos % COLS : 0;
        var lin = modo === 'folha' ? Math.floor(pos / COLS) : 0;

        crachaNoPdf(doc, DADOS[i],
          margemX + col * CRACHA.larg * (modo === 'ampliado' ? escala : 1),
          margemY + lin * CRACHA.alt,
          escala);

        if (i % 20 === 0) {
          aviso.textContent = 'Desenhando… ' + (i + 1) + ' de ' + DADOS.length;
          await new Promise(function (r) { setTimeout(r, 0); });
        }
      }

      doc.save(APELIDO + '-' + modo + '.pdf');
      aviso.textContent = 'PDF pronto: ' + DADOS.length + ' crachá(s) em '
        + doc.getNumberOfPages() + ' página(s). Texto e QR em vetor.';
    } catch (e) {
      aviso.textContent = 'Falhou: ' + (e && e.message ? e.message : e)
        + '. O Ctrl+P → Salvar como PDF continua funcionando sem depender de internet.';
    } finally {
      btn.disabled = false;
    }
  });

  function blobDoCanvas(canvas) {
    return new Promise(function (ok) { canvas.toBlob(ok, 'image/png'); });
  }

  document.getElementById('btn-png').addEventListener('click', async function () {
    var btn = this, aviso = document.getElementById('progresso');
    var modo = document.getElementById('modo').value;
    var dpi = Number(document.getElementById('dpi').value);
    btn.disabled = true;

    try {
      if (!window.JSZip) {
        aviso.textContent = 'Carregando compactador…';
        await new Promise(function (ok, erro) {
          var s = document.createElement('script');
          s.src = 'https://cdn.jsdelivr.net/npm/jszip@3.10.1/dist/jszip.min.js';
          s.onload = ok; s.onerror = function () { erro(new Error('sem internet')); };
          document.head.appendChild(s);
        });
      }

      var zip = new JSZip();
      var canvas = document.createElement('canvas');
      var ctx = canvas.getContext('2d');
      // 2 colunas x 7 linhas de 80x40mm cabem na A4 útil.
      var COLS = 2, LINS = 7;
      var porFolha = modo === 'folha' ? COLS * LINS : 1;
      var total = Math.ceil(DADOS.length / porFolha);

      for (var p = 0; p < total; p++) {
        var grupo = DADOS.slice(p * porFolha, (p + 1) * porFolha);

        /* A folha é do tamanho da grade, não da A4 inteira:
           2x7 crachás de 80x40mm dão 160x280mm, que cabe na área
           útil (194x281mm) sem sobra pendurada na direita. */
        if (modo === 'cracha') {
          canvas.width = Math.round(mm(CRACHA.larg, dpi));
          canvas.height = Math.round(mm(CRACHA.alt, dpi));
        } else if (modo === 'ampliado') {
          /* 1 por folha: o crachá ampliado até a largura útil da
             A4, centralizado. 194/80 = 2,425 — o QR vai de 34 para
             82mm. Não tem proporção redonda como antes, então
             sobra margem em cima e embaixo. */
          canvas.width = Math.round(mm(194, dpi));
          canvas.height = Math.round(mm(281, dpi));
        } else {
          canvas.width = Math.round(mm(CRACHA.larg * COLS, dpi));
          canvas.height = Math.round(mm(CRACHA.alt * LINS, dpi));
        }
        ctx.fillStyle = '#fff';
        ctx.fillRect(0, 0, canvas.width, canvas.height);

        for (var g = 0; g < grupo.length; g++) {
          if (modo === 'ampliado') {
            var escala = 194 / CRACHA.larg;
            desenharCracha(ctx, grupo[g], 0,
              (canvas.height - mm(CRACHA.alt * escala, dpi)) / 2, dpi * escala);
          } else {
            var col = modo === 'folha' ? g % COLS : 0;
            var lin = modo === 'folha' ? Math.floor(g / COLS) : 0;
            desenharCracha(ctx, grupo[g],
              col * mm(CRACHA.larg, dpi), lin * mm(CRACHA.alt, dpi), dpi);
          }
        }

        var limpo = function (s) {
          return String(s || 'sem-nome').normalize('NFD').replace(/[\\u0300-\\u036f]/g, '')
            .replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase();
        };
        var nome = modo === 'folha'
          ? 'folha-' + String(p + 1).padStart(3, '0') + '.png'
          : String(p + 1).padStart(3, '0') + '-' + limpo(grupo[0].nome) + '.png';

        zip.file(nome, await blobDoCanvas(canvas));
        aviso.textContent = 'Desenhando… ' + (p + 1) + ' de ' + total;
        await new Promise(function (r) { setTimeout(r, 0); });   // deixa a tela respirar
      }

      aviso.textContent = 'Compactando ' + total + ' imagem(ns)…';
      var arquivo = await zip.generateAsync({ type: 'blob', compression: 'STORE' });
      var url = URL.createObjectURL(arquivo);
      var a = document.createElement('a');
      a.href = url;
      a.download = APELIDO + '-' + modo + '-' + dpi + 'dpi.zip';
      a.click();
      setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
      aviso.textContent = 'Pronto: ' + total + ' imagem(ns) a ' + dpi + ' DPI. Confira antes de mandar para a gráfica.';
    } catch (e) {
      aviso.textContent = 'Falhou: ' + (e && e.message ? e.message : e) +
        '. Se for falta de internet, o compactador não carrega — o PDF pelo Ctrl+P não depende disso.';
    } finally {
      btn.disabled = false;
    }
  });
<\/script>

</body>
</html>
`;
};

mkdirSync('saida', { recursive: true });

/* Os arquivos são escritos depois do carimbo. Se a escrita falhar
   aqui, a leva já existe no banco e `--lote N` a reconstrói
   inteira — nunca é preciso recomeçar do zero nem correr o risco
   de gerar um segundo crachá para a mesma pessoa.

   Um arquivo por categoria porque é assim que os crachás são
   separados na mesa: aluno vai para o kit da turma, responsável é
   entregue na entrada, counselor e docente são recebidos à parte.
   Um PDF só obrigaria a recortar e reagrupar 515 papéis à mão. */
const escritos = [];

for (const g of GRUPOS) {
  const lista = pessoas.filter(p => p.grupo === g.chave);
  if (!lista.length) continue;

  /* No modo --externos o prefixo já é "crachas-externos"; repetir
     o grupo daria crachas-externos-externos.html. */
  const raiz = base.replace(/^saida\//, '');
  const apelido = raiz.endsWith('-' + g.chave) ? raiz : `${raiz}-${g.chave}`;
  const caminho = `saida/${apelido}.html`;
  writeFileSync(caminho, montarHtml(lista, g.titulo, apelido), 'utf8');
  escritos.push({ caminho, titulo: g.titulo, n: lista.length });
}

const total = escritos.reduce((n, e) => n + e.n, 0);

console.log(`${total} crachá(s) em ${escritos.length} arquivo(s):`);
for (const e of escritos) {
  console.log(`  ${String(e.n).padStart(4)}  ${e.titulo.padEnd(20)} ${e.caminho}`);
}
console.log(`\nURL no QR: ${URL_APP}/#/p/<token>`);

if (lote && !EXEMPLO && LOTE_PEDIDO === null) {
  console.log(`\nEsta é a leva ${lote}. Essa gente não volta em geração nenhuma daqui`);
  console.log(`em diante. Se os arquivos não forem impressos, devolva todos para a fila com:`);
  console.log(`  node scripts/gerar-crachas.mjs --desmarcar ${lote}`);
  console.log(`Para reimprimir a mesma leva depois: --lote ${lote}`);
}

console.log('\nAbra cada arquivo no navegador e imprima com Ctrl+P — um de cada vez.');
console.log('Contêm dado pessoal de menores: não publique e apague depois de imprimir.');
