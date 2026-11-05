/* ============================================================
   Leads do evento, um pacote por avaliador

   Depois da feira cada representante quer a lista de quem ele
   escaneou. Esta é a etapa "envio pós-evento" da seção 9 dos
   requisitos: agrupa os contatos por avaliador, gera uma planilha
   e um HTML por pessoa, e monta um índice para o envio manual.

   USO (PowerShell):
     node scripts/leads-avaliadores.mjs

   A chave sai de segredo-supabase.txt (ou da variável de
   ambiente). Veja scripts/chave.mjs.

   POR QUE O SCRIPT REAPLICA AS REGRAS DE COMPARTILHAMENTO

   A service_role ignora RLS e não passa por perfil_aluno(). Lendo
   `alunos` direto vem tudo: telefone de menor de idade que marcou
   nível 1, contato de responsável que não autorizou. Se o filtro
   não for refeito aqui, o vazamento sai por e-mail, assinado pela
   organização, para uma universidade de fora.

   Então as regras da 0003/0005/0019 estão repetidas abaixo, em
   JavaScript, e as colunas da planilha são exatamente as que o
   perfil_aluno devolve. Mudou a regra no banco? Mude aqui junto —
   é o preço de ler pela porta dos fundos.

   REVOGAÇÃO

   `salvar_contato` exigiu autorização no momento do scan. Quem
   revogou depois — consentimento derrubado, nível zerado — sai da
   exportação inteira, não vai com as colunas em branco. O contato
   continua no banco; ele só não é mais distribuído. A contagem de
   removidos aparece no fim e no índice.

   ATENÇÃO: saida/leads/ tem nome, e-mail e telefone de menores de
   idade, separados por destinatário. Mesma regra do crachá e do
   painel — não publique, não suba para o Drive, apague depois do
   envio. Rodar de novo regenera.
   ============================================================ */

import { writeFileSync, mkdirSync } from 'node:fs';
import { exigirChave, exigirUrl } from './chave.mjs';
import { montarXlsx } from './xlsx.mjs';

const URL_PROJETO = exigirUrl();
const CHAVE = exigirChave();
const PASTA = 'saida/leads';

/* ------------------------------------------------------------
   --patrocinador "Nome" — o pacote do patrocinador master

   Sai DESLIGADO por padrão, e é para continuar assim.

   O pacote do avaliador tem uma base clara: ele escaneou aquele
   crachá, a família autorizou compartilhamento com avaliadores
   para contato posterior, e a lista dele é o que ele mesmo
   registrou. O do patrocinador é outra coisa — são todos os
   alunos que estiveram na feira, inclusive os que ninguém visitou,
   para alguém que não escaneou ninguém.

   O termo que o responsável assinou (0010, e o item de finalidade
   da seção 10 dos requisitos) fala em compartilhamento com
   avaliadores. Se patrocinador entra nessa palavra, quem responde
   é quem redigiu o termo, não este script. Por isso a flag: o
   arquivo só existe quando alguém digita o nome do patrocinador e
   assume a decisão.

   O que o script garante de qualquer forma: as mesmas regras de
   nível de compartilhamento, e nota e comentário de avaliador
   FORA — aquilo é anotação de trabalho de terceiro, escrita sobre
   um aluno, e não pertence a mais ninguém.
   ------------------------------------------------------------ */
const argumentos = process.argv.slice(2);

function opcao(nome, padrao = null) {
  const i = argumentos.indexOf('--' + nome);
  if (i === -1) return null;
  const v = argumentos[i + 1];
  return !v || v.startsWith('--') ? padrao : v;
}

const PATROCINADOR = argumentos.includes('--patrocinador')
  ? opcao('patrocinador', 'Patrocinador master') : null;

/* --site https://seu-dominio — endereço onde a pesquisa está
   publicada. Sem ele o índice mostra só o token, que não serve
   para colar em e-mail nenhum.

   --pagina avaliacao.html — para hospedagem que serve o arquivo
   com a extensão. O padrão é SEM, porque o Cloudflare (onde este
   projeto é publicado) responde 307 de /avaliacao.html para
   /avaliacao — e redirecionamento é justamente onde o #token se
   perde. Um link que chega direto na página final não tem esse
   risco. */
const SITE = (opcao('site') || '').replace(/\/+$/, '');
const PAGINA = (opcao('pagina') || 'avaliacao').replace(/^\/+/, '');

/* O código de 8 posições (0050) sai partido no meio no link:
   `K7M2-QX9R` em vez de `K7M2QX9R`. Oito caracteres corridos são
   difíceis de ler em voz alta e de conferir num print; em dois
   blocos de quatro, o olho pega de uma vez.

   O hífen é enfeite: não está guardado no banco, e a
   normalizar_codigo() o descarta antes da consulta. Link com,
   sem, em minúscula ou com espaço no meio abrem igual. Token
   antigo de 32 hex passa intacto. */
const comHifen = t =>
  String(t || '').length === 8 ? String(t).slice(0, 4) + '-' + String(t).slice(4) : t;

/* --org "IE" — de qual organização são os representantes do pacote
   por pessoa. Sem isso, usa o próprio nome do patrocinador, que é
   o caso comum: a IE manda gente da IE. Compara com
   avaliadores.organizacao sem acento e sem caixa. */
const ORG = opcao('org') || PATROCINADOR;

/* --pacote presentes,representantes,inscritos

   Três recortes diferentes, e cada um responde a uma pergunta
   distinta — por isso são arquivos separados, e não abas do mesmo:

     presentes     quem esteve na feira (padrão, o de sempre)
     representantes  o que CADA pessoa da organização leu, uma aba
                   por pessoa
     inscritos     todos os inscritos no evento, alunos numa aba e
                   responsáveis noutra, tenham comparecido ou não

   O último é o mais largo de todos: inclui quem se inscreveu e não
   apareceu. Vale reler o aviso de finalidade acima antes de mandar. */
const PACOTES = new Set(
  (opcao('pacote', 'presentes') || 'presentes').split(',').map(s => s.trim()).filter(Boolean));

if (PATROCINADOR) {
  const validos = ['presentes', 'representantes', 'inscritos'];
  const errado = [...PACOTES].find(p => !validos.includes(p));
  if (errado) {
    console.error(`Pacote desconhecido: "${errado}". Use ${validos.join(', ')}.`);
    process.exit(1);
  }
}

/* ------------------------------------------------------------
   Leitura

   O PostgREST devolve no máximo 1000 linhas por chamada e não
   avisa quando corta. Com ~600 alunos e vários contatos por
   avaliador, o teto é alcançável — daí a paginação.

   A ordenação precisa ser ÚNICA, senão duas páginas podem trazer
   a mesma linha e deixar outra de fora. Por isso `contatos_salvos`
   ordena pelas duas colunas da chave primária, não por uma só.
   ------------------------------------------------------------ */
async function ler(tabela, colunas, ordem = 'id', { tolerante = false } = {}) {
  const tudo = [];
  const PAGINA = 1000;

  for (let salto = 0; ; salto += PAGINA) {
    const caminho =
      `${tabela}?select=${colunas}&order=${ordem}&limit=${PAGINA}&offset=${salto}`;

    const r = await fetch(`${URL_PROJETO}/rest/v1/${caminho}`, {
      headers: { apikey: CHAVE, Authorization: 'Bearer ' + CHAVE }
    });
    if (!r.ok) {
      const texto = await r.text();
      /* `tolerante` é para leitura que tem plano B — quem chamou
         decide. Sem isso, o erro mata o processo aqui dentro e o
         plano B nunca roda. */
      if (tolerante) throw new Error(texto);
      console.error(`Falha ao ler ${tabela}:`, texto);
      process.exit(1);
    }

    const lote = await r.json();
    tudo.push(...lote);
    if (lote.length < PAGINA) return tudo;
  }
}

/* `avaliacao_token` só existe depois da 0049. Enquanto a migration
   não for aplicada, o PostgREST recusa a coluna e derruba a
   leitura inteira — por um link de pesquisa que é acessório. Então
   tenta com, e cai para sem. */
let temPesquisa = true;
const avaliadores = await ler(
  'avaliadores', 'id,nome,email,organizacao,papel,avaliacao_token', 'id', { tolerante: true }
).catch(() => {
  temPesquisa = false;
  return ler('avaliadores', 'id,nome,email,organizacao,papel');
});
const contatos = await ler('contatos_salvos',
  'avaliador_id,aluno_id,nota,comentario,criado_em',
  'avaliador_id.asc,aluno_id.asc');
const alunos = await ler('alunos',
  'id,nome,codigo_curto,tipo,ativo,presente,presente_em,nivel_compartilhamento,' +
  'consentimento_responsavel,compartilhar_responsavel,aluno_alfacem,colegio,unidade,' +
  'segmento,ano_escolaridade,paises_interesse,motivo,experiencia_internacional,' +
  'email,telefone,parentesco,responsavel_nome,responsavel_email,responsavel_telefone');

/* O log só interessa aos pacotes do patrocinador, e são mais de
   mil linhas: sem a flag, não se lê. Idem os acompanhantes, que só
   o pacote de inscritos usa. */
const acessos = PATROCINADOR
  ? await ler('log_acesso', 'aluno_id,avaliador_id') : [];

/* O código do link geral da pesquisa (0052). Como tudo que
   depende de migration ainda não aplicada, falha em silêncio: o
   índice mostra os links pessoais e segue. */
const pesquisa = (await ler('pesquisa_evento', 'codigo,aberta', 'id', { tolerante: true })
  .catch(() => []))[0] || null;

const acompanhantes = PATROCINADOR && PACOTES.has('inscritos')
  ? await ler('acompanhantes', 'id,aluno_id,nome,parentesco,email,telefone,presente,presente_em')
  : [];

/* ------------------------------------------------------------
   As regras do banco, de novo

   nivel_efetivo (0003), responsavel_liberado e pode_salvar (0005).
   ------------------------------------------------------------ */
/* Parentesco é vocabulário fechado do formulário — três valores, e
   os três aparecem na planilha que vai para universidade
   estrangeira. Traduzir aqui é seguro; o resto das respostas do
   aluno continua em português.

   Valor fora da lista passa intacto em vez de virar vazio: se o
   formulário ganhar uma opção nova, a planilha mostra a nova opção
   em português em vez de perder o dado. */
const PARENTESCO = {
  'Mãe': 'Mãe / Mother',
  'Pai': 'Pai / Father',
  'Outro responsável legal': 'Outro responsável legal / Other legal guardian'
};

const nivel = a => (a.consentimento_responsavel ? a.nivel_compartilhamento : 0);
const respLiberado = a => !!(a.consentimento_responsavel && a.compartilhar_responsavel);
const podeSalvar = a => nivel(a) >= 1 || respLiberado(a);

/* Espelha o jsonb de perfil_aluno() na 0019. Campo que a função
   devolveria nulo sai vazio aqui — nunca com o valor da coluna.

   É a única porta por onde dado de aluno entra em qualquer
   arquivo gerado aqui, seja o do avaliador ou o do patrocinador.
   Uma porta só é o que torna a regra conferível. */
function camposDoAluno(a) {
  const n = nivel(a);
  const acad = v => (n >= 1 ? v : null);
  const contato = v => (n >= 2 ? v : null);
  const resp = v => (respLiberado(a) ? v : null);

  return {
    nome: a.nome,
    codigo: a.codigo_curto,
    instituicao: acad(a.colegio || a.unidade ||
                      (a.aluno_alfacem ? 'Rede Alfacem Global Academy' : null)),
    segmento: acad(a.segmento),
    ano: acad(a.ano_escolaridade),
    paises: acad((a.paises_interesse || []).join(', ')),
    motivo: acad(a.motivo),
    experiencia: acad(a.experiencia_internacional),
    email: contato(a.email),
    telefone: contato(a.telefone),
    responsavel: resp(a.responsavel_nome),
    parentesco: resp(PARENTESCO[a.parentesco] || a.parentesco),
    resp_email: resp(a.responsavel_email),
    resp_telefone: resp(a.responsavel_telefone)
  };
}

/* O que o avaliador acrescenta ao aluno: a visita dele. */
const linhaDoLead = (a, c) => ({
  ...camposDoAluno(a),
  nota: c.nota,
  comentario: c.comentario,
  salvo_em: quando(c.criado_em)
});

/* Horário de Brasília, no formato da planilha. O banco devolve
   UTC; sem o timeZone explícito o carimbo muda conforme o
   relógio da máquina que rodou o script. */
function quando(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo',
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit'
  }).replace(',', '');
}

/* Cabeçalho nos dois idiomas, na mesma célula.

   A maior parte de quem recebe estes arquivos é de universidade
   estrangeira e não lê português. Duas linhas de cabeçalho
   quebrariam o filtro e a ordenação do Excel, e uma aba traduzida
   ao lado dobraria o arquivo e as chances de mandar a errada. Na
   mesma célula custa largura de coluna — que o gerador já mede
   sozinha — e resolve.

   `tipo` só aparece onde a coluna não é texto: a nota precisa
   somar e ordenar como número, e "salvo em" precisa ordenar como
   data — em texto, 01/09 viria antes de 22/08. */
const col = (chave, pt, en, tipo) => ({ chave, titulo: `${pt} / ${en}`, tipo });

const COLUNAS = [
  col('nome',          'Nome',                     'Name'),
  col('codigo',        'Código do crachá',         'Badge code'),
  col('instituicao',   'Instituição',              'School'),
  col('segmento',      'Segmento',                 'Level'),
  col('ano',           'Ano de escolaridade',      'Grade'),
  col('paises',        'Países de interesse',      'Countries of interest'),
  col('motivo',        'Motivo',                   'Interest'),
  col('experiencia',   'Experiência internacional', 'International experience'),
  col('email',         'E-mail',                   'Email'),
  col('telefone',      'Telefone',                 'Phone'),
  col('responsavel',   'Responsável',              'Guardian'),
  col('parentesco',    'Parentesco',               'Relationship'),
  col('resp_email',    'E-mail do responsável',    'Guardian email'),
  col('resp_telefone', 'Telefone do responsável',  'Guardian phone'),
  col('nota',          'Nota',                     'Rating', 'numero'),
  col('comentario',    'Comentário',               'Comment'),
  col('salvo_em',      'Salvo em',                 'Saved at', 'data')
];

/* As mesmas colunas do aluno, sem as três do avaliador: nota e
   comentário são a opinião de um representante sobre um menor,
   escrita para uso dele. Não vão para o patrocinador. No lugar
   entra como a pessoa apareceu no evento. */
const COLUNAS_PATROCINADOR = [
  ...COLUNAS.filter(c => !['nota', 'comentario', 'salvo_em'].includes(c.chave)),
  col('presenca',       'Presença',       'Attendance'),
  col('credenciado_em', 'Credenciado em', 'Checked in at', 'data')
];

/* Acompanhante tem ficha própria e curta: nome, parentesco e o
   aluno de quem veio junto. Nada de acadêmico — a pessoa não é
   aluna. */
const COLUNAS_RESPONSAVEIS = [
  col('nome',       'Nome',       'Name'),
  col('parentesco', 'Parentesco', 'Relationship'),
  col('acompanha',  'Acompanha',  'Accompanying'),
  col('email',      'E-mail',     'Email'),
  col('telefone',   'Telefone',   'Phone'),
  col('presenca',   'Presença',   'Attendance'),
  col('credenciado_em', 'Credenciado em', 'Checked in at', 'data')
];

/* Aba de rosto do arquivo por representante. Sem ela, quem abrir
   não descobre que dois dos quatro cadastrados não leram nada — só
   veria duas abas e concluiria que faltou gente no arquivo. */
const COLUNAS_RESUMO = [
  col('nome',     'Representante', 'Representative'),
  col('email',    'E-mail',        'Email'),
  col('lidos',    'Crachás lidos', 'Badges scanned', 'numero'),
  col('salvos',   'Contatos salvos', 'Contacts saved', 'numero'),
  col('aba',      'Aba com a lista', 'Tab with the list')
];

/* ------------------------------------------------------------
   Montagem
   ------------------------------------------------------------ */
const alunoPorId = new Map(alunos.map(a => [a.id, a]));

const semAluno = [];     // contato órfão: não deveria existir (cascade)
const revogados = [];    // autorizou no dia, revogou depois

const porAvaliador = new Map();
for (const c of contatos) {
  const a = alunoPorId.get(c.aluno_id);
  if (!a) { semAluno.push(c); continue; }
  if (!podeSalvar(a)) { revogados.push({ c, a }); continue; }

  if (!porAvaliador.has(c.avaliador_id)) porAvaliador.set(c.avaliador_id, []);
  porAvaliador.get(c.avaliador_id).push(linhaDoLead(a, c));
}

/* Ordem alfabética por nome, com localeCompare para 'Ávila' não
   cair depois de 'Zuza' — mesmo cuidado da chave_nome() da 0026. */
const emOrdem = l => l.sort((x, y) => x.nome.localeCompare(y.nome, 'pt-BR'));

/* ------------------------------------------------------------
   Quem esteve na feira

   Duas evidências, e a união das duas — não só a primeira:

     1. `presente` — passou pelo credenciamento na entrada;
     2. `log_acesso` — um avaliador leu o crachá no salão.

   Só o credenciamento deixaria de fora quem entrou sem passar
   pela mesa e mesmo assim foi escaneado por três universidades.
   Aconteceu com 13 pessoas nesta edição: estavam lá de forma
   demonstrável, e a lista do patrocinador as perderia em silêncio.

   Counselor e docente ficam fora: são adultos de outra base de
   inscrição, e o pedido é a lista de ALUNOS da feira.
   ------------------------------------------------------------ */
const escaneados = new Set(acessos.map(l => l.aluno_id));

const naFeira = !PATROCINADOR ? [] : alunos
  .filter(a => (a.tipo || 'aluno') === 'aluno')
  .filter(a => a.presente || escaneados.has(a.id))
  .filter(a => podeSalvar(a))
  .map(a => ({
    ...camposDoAluno(a),
    /* Valor gerado aqui, então sai bilíngue como o cabeçalho. */
    presenca: a.presente ? 'Credenciado na entrada / Checked in at the door'
                         : 'Lido por avaliador no salão / Badge scanned at the fair',
    credenciado_em: quando(a.presente_em)
  }));

/* Esteve na feira e hoje não autoriza mais. Mesma regra do pacote
   do avaliador: sai da exportação inteira, não com colunas vazias. */
const naFeiraSemAutorizacao = !PATROCINADOR ? [] : alunos
  .filter(a => (a.tipo || 'aluno') === 'aluno')
  .filter(a => a.presente || escaneados.has(a.id))
  .filter(a => !podeSalvar(a));

/* ------------------------------------------------------------
   Pacote "representantes": uma aba por pessoa da organização

   O patrocinador manda gente para o estande e quer ver o que cada
   uma trouxe, separado — não um monte só. Uma aba por pessoa é
   exatamente isso, e mantém tudo num anexo em vez de quatro.

   Aqui nota e comentário ENTRAM, ao contrário do pacote de
   presentes: quem escreveu foi a própria equipe do patrocinador,
   sobre quem ela mesma atendeu. É anotação da casa voltando para
   casa, não anotação de terceiro.
   ------------------------------------------------------------ */
const semAcento = t => String(t || '')
  .normalize('NFD').replace(/[̀-ͯ]/g, '').trim().toLowerCase();

const lidosPor = new Map();
for (const l of acessos) {
  if (!lidosPor.has(l.avaliador_id)) lidosPor.set(l.avaliador_id, new Set());
  lidosPor.get(l.avaliador_id).add(l.aluno_id);
}

const daOrganizacao = !PATROCINADOR || !ORG ? [] : avaliadores
  .filter(av => semAcento(av.organizacao) === semAcento(ORG))
  .map(av => ({
    av,
    lidos: (lidosPor.get(av.id) || new Set()).size,
    linhas: emOrdem(porAvaliador.get(av.id) || [])
  }))
  .sort((x, y) => y.linhas.length - x.linhas.length ||
                  x.av.nome.localeCompare(y.av.nome, 'pt-BR'));

/* Só quem leu algum crachá ganha aba. Quem não leu aparece no
   resumo com zero — some da lista de abas, não da prestação de
   contas. */
const comLeitura = daOrganizacao.filter(r => r.linhas.length > 0);

/* ------------------------------------------------------------
   Pacote "inscritos": todos os inscritos, tenham vindo ou não

   Duas abas, porque são duas fichas diferentes: aluno tem bloco
   acadêmico, acompanhante não tem nada disso.

   SOBRE O CONTATO DO ACOMPANHANTE

   `acompanhantes` não tem coluna de consentimento própria — o
   schema nunca previu compartilhar esta lista, ela existe para
   crachá e credenciamento. O único opt-in registrado que toca
   contato de adulto responsável é o `compartilhar_responsavel` do
   aluno vinculado, e é ele que libera e-mail e telefone aqui.

   Na prática não se perde nada: os 313 acompanhantes com e-mail e
   os 314 com telefone estão todos dentro dos 388 cujo aluno
   liberou. Mas a regra fica escrita, e quem tiver de responder por
   ela depois encontra o critério em vez de ter de reconstruí-lo.
   ------------------------------------------------------------ */
const presencaDoAluno = a =>
  a.presente        ? 'Credenciado na entrada / Checked in at the door' :
  escaneados.has(a.id) ? 'Lido por avaliador no salão / Badge scanned at the fair'
                       : 'Não compareceu / Did not attend';

const alunosInscritos = !PATROCINADOR || !PACOTES.has('inscritos') ? [] : emOrdem(alunos
  .filter(a => (a.tipo || 'aluno') === 'aluno')
  .filter(a => podeSalvar(a))
  .map(a => ({
    ...camposDoAluno(a),
    presenca: presencaDoAluno(a),
    credenciado_em: quando(a.presente_em)
  })));

const responsaveisInscritos = !PATROCINADOR || !PACOTES.has('inscritos') ? [] : emOrdem(
  acompanhantes.map(c => {
    const a = alunoPorId.get(c.aluno_id);
    const liberado = a ? respLiberado(a) : false;

    return {
      nome: c.nome,
      parentesco: PARENTESCO[c.parentesco] || c.parentesco,
      acompanha: a ? a.nome : '',
      email: liberado ? c.email : null,
      telefone: liberado ? c.telefone : null,
      presenca: c.presente ? 'Credenciado na entrada / Checked in at the door'
                           : 'Não compareceu / Did not attend',
      credenciado_em: quando(c.presente_em)
    };
  }));

const esc = t => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function apelido(txt) {
  return String(txt || '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
    .slice(0, 40) || 'sem-nome';
}

/* A planilha de um avaliador. O nome da aba é o dele: quem
   receber três arquivos por engano descobre de quem é cada um
   sem abrir a coluna A. */
const planilhaDoAvaliador = (av, linhas) =>
  montarXlsx([{ nome: av.nome, colunas: COLUNAS, linhas }]);

const ESTILO = `
  :root { --azul:#1478d0; --texto:#201e1d; --cinza:#605d5d; --linha:#e3e0e0; }
  * { box-sizing:border-box; }
  body { margin:0; background:#f3f2f2; color:var(--texto);
         font:15px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif; }
  .env { max-width:1080px; margin:0 auto; padding:28px 20px 60px; }
  header { border-bottom:2px solid var(--texto); padding-bottom:14px; margin-bottom:18px; }
  h1 { margin:0 0 4px; font-size:22px; letter-spacing:-.02em; }
  .sub { font-size:13px; color:var(--cinza); }
  .aviso { margin:0 0 24px; padding:12px 16px; background:#fff4d6; color:#7a5100;
           border-left:5px solid #d69a00; font-size:13.5px; }
  section { background:#fff; border:1px solid var(--linha); padding:18px 20px; margin-bottom:18px; }
  h2 { margin:0 0 14px; font-size:15px; text-transform:uppercase; letter-spacing:.08em; color:var(--cinza); }
  table { width:100%; border-collapse:collapse; font-size:14px; }
  th { text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:.07em;
       color:var(--cinza); border-bottom:1px solid var(--linha); padding:7px 10px 7px 0; }
  td { padding:8px 10px 8px 0; border-bottom:1px solid #f1efef; vertical-align:top; }
  .vazio { color:var(--cinza); font-size:13.5px; }
  .nota { white-space:nowrap; font-variant-numeric:tabular-nums; }
  .obs { color:var(--cinza); font-size:13px; }
  a { color:var(--azul); }
  @media print { body { background:#fff; } section { border:0; padding:0; } .aviso { display:none; } }
`;

function paginaDoAvaliador(av, linhas) {
  return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Contatos de ${esc(av.nome)} — Alfa University Fair</title>
<style>${ESTILO}</style>
</head>
<body>
<div class="env">

<header>
  <h1>Seus contatos / Your contacts · Alfa University Fair</h1>
  <div class="sub">${esc(av.nome)}${av.organizacao ? ' · ' + esc(av.organizacao) : ''}
    · ${linhas.length} contato(s) / contacts</div>
</header>

<p class="aviso">Estes dados foram compartilhados com autorização do responsável,
para contato posterior sobre oportunidades acadêmicas. Use apenas para essa
finalidade e não repasse a terceiros. Para pedir a exclusão de um registro,
responda ao e-mail que trouxe esta lista.<br><br>
<i>This data was shared with the legal guardian's consent, for follow-up contact
about academic opportunities. Please use it for that purpose only and do not
share it with third parties. To request removal of a record, reply to the email
that delivered this list.</i></p>

<section>
  <h2>Contatos salvos / Saved contacts</h2>
  ${linhas.length ? `<table>
    <tr>
      <th>Nome<br>Name</th><th>Instituição<br>School</th><th>Ano<br>Grade</th>
      <th>Países<br>Countries</th><th>Contato<br>Contact</th>
      <th>Responsável<br>Guardian</th><th>Nota<br>Rating</th>
      <th>Comentário<br>Comment</th><th>Salvo em<br>Saved at</th>
    </tr>
    ${linhas.map(l => `<tr>
      <td>${esc(l.nome)}<br><span class="obs">${esc(l.codigo)}</span></td>
      <td>${esc(l.instituicao || '—')}</td>
      <td>${esc(l.ano || '—')}</td>
      <td>${esc(l.paises || '—')}</td>
      <td>${esc(l.email || '')}${l.email && l.telefone ? '<br>' : ''}${esc(l.telefone || '')}
          ${!l.email && !l.telefone ? '<span class="obs">—</span>' : ''}</td>
      <td>${esc(l.responsavel || '')}${l.resp_email ? '<br>' + esc(l.resp_email) : ''}
          ${l.resp_telefone ? '<br>' + esc(l.resp_telefone) : ''}
          ${!l.responsavel && !l.resp_email && !l.resp_telefone ? '<span class="obs">—</span>' : ''}</td>
      <td class="nota">${l.nota == null ? '—' : esc(l.nota) + '/5'}</td>
      <td>${esc(l.comentario || '—')}</td>
      <td class="obs">${esc(l.salvo_em)}</td>
    </tr>`).join('')}
  </table>` : '<p class="vazio">Nenhum contato salvo. / No saved contacts.</p>'}
</section>

<p class="obs">Alguns campos aparecem vazios porque a família autorizou apenas
parte deles. É a escolha registrada na inscrição, não falha de preenchimento.<br>
<i>Some fields are empty because the family authorised only part of them. That is
the choice recorded at registration, not missing data.</i></p>

</div>
</body>
</html>
`;
}

function paginaDoPatrocinador(linhas) {
  const credenciados = linhas.filter(l => l.presenca.startsWith('Credenciado')).length;

  return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Alunos da feira — ${esc(PATROCINADOR)}</title>
<style>${ESTILO}</style>
</head>
<body>
<div class="env">

<header>
  <h1>Alunos presentes / Students who attended · Alfa University Fair</h1>
  <div class="sub">${esc(PATROCINADOR)} · ${linhas.length} aluno(s) / students ·
    ${credenciados} pelo credenciamento, ${linhas.length - credenciados} por leitura de crachá</div>
</header>

<p class="aviso">Estes dados foram compartilhados com autorização do responsável,
para contato posterior sobre oportunidades acadêmicas. Use apenas para essa
finalidade e não repasse a terceiros. Para pedir a exclusão de um registro,
responda ao e-mail que trouxe esta lista.<br><br>
<i>This data was shared with the legal guardian's consent, for follow-up contact
about academic opportunities. Please use it for that purpose only and do not
share it with third parties. To request removal of a record, reply to the email
that delivered this list.</i></p>

<section>
  <h2>Alunos que estiveram no evento / Students present at the fair</h2>
  <table>
    <tr>
      <th>Nome<br>Name</th><th>Instituição<br>School</th><th>Ano<br>Grade</th>
      <th>Países<br>Countries</th><th>Contato<br>Contact</th>
      <th>Responsável<br>Guardian</th><th>Presença<br>Attendance</th>
    </tr>
    ${linhas.map(l => `<tr>
      <td>${esc(l.nome)}<br><span class="obs">${esc(l.codigo)}</span></td>
      <td>${esc(l.instituicao || '—')}</td>
      <td>${esc(l.ano || '—')}</td>
      <td>${esc(l.paises || '—')}</td>
      <td>${esc(l.email || '')}${l.email && l.telefone ? '<br>' : ''}${esc(l.telefone || '')}
          ${!l.email && !l.telefone ? '<span class="obs">—</span>' : ''}</td>
      <td>${esc(l.responsavel || '')}${l.resp_email ? '<br>' + esc(l.resp_email) : ''}
          ${l.resp_telefone ? '<br>' + esc(l.resp_telefone) : ''}
          ${!l.responsavel && !l.resp_email && !l.resp_telefone ? '<span class="obs">—</span>' : ''}</td>
      <td class="obs">${esc(l.presenca)}${l.credenciado_em ? '<br>' + esc(l.credenciado_em) : ''}</td>
    </tr>`).join('')}
  </table>
</section>

<p class="obs">A lista não traz nota nem comentário: aquilo é anotação de
trabalho de cada representante de universidade, sobre o aluno que ele
visitou, e não é compartilhada. Campos vazios são escolha registrada pela
família na inscrição, não falha de preenchimento.<br>
<i>This list carries no rating or comment: those are each university
representative's working notes about the students they met, and are not
shared. Empty fields are the family's choice recorded at registration, not
missing data.</i></p>

</div>
</body>
</html>
`;
}

/* ------------------------------------------------------------
   Escrita
   ------------------------------------------------------------ */
mkdirSync(PASTA, { recursive: true });

/* O nome do arquivo é o e-mail de quem vai receber.

   O envio é manual, um e-mail por vez, com anexo escolhido à mão
   numa pasta de dezenas de planilhas. Nome de pessoa não protege
   contra o erro que importa: dois "João Silva" geram o mesmo
   apelido, e o parecido — "rachel-yoon" e "rachel-yoon-2" — é
   pior ainda, porque some numa lista ordenada. Anexar a lista da
   Marina para o Rodrigo não dá erro nenhum: dá um vazamento
   silencioso de dado de menor para a universidade errada.

   O e-mail é único por construção (`avaliadores.email` tem
   UNIQUE) e é exatamente o que já está sendo digitado no campo
   "Para". Procurar o anexo pelo mesmo texto fecha o circuito.

   O @ e o ponto são legais em nome de arquivo no Windows, no Mac
   e no Linux. Ainda assim, qualquer caractere que algum sistema
   de arquivos recuse vira hífen — e-mail estranho não pode
   derrubar a geração no meio. */
const nomesUsados = new Map();
const pacotes = [];

function arquivoDe(av) {
  const limpo = String(av.email || '').trim().toLowerCase()
    .replace(/[\\/:*?"<>|\s]+/g, '-') || apelido(av.nome);

  /* Cinto e suspensório: o UNIQUE do banco já impede o empate, mas
     o dia em que alguém remover a constraint não é o dia de
     descobrir que uma planilha sobrescreveu a outra. */
  const repetido = (nomesUsados.get(limpo) || 0) + 1;
  nomesUsados.set(limpo, repetido);
  return repetido > 1 ? `${limpo}-${repetido}` : limpo;
}

for (const av of avaliadores.sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR'))) {
  const linhas = emOrdem(porAvaliador.get(av.id) || []);
  if (!linhas.length) { pacotes.push({ av, linhas, arquivo: null }); continue; }

  const base = arquivoDe(av);

  writeFileSync(`${PASTA}/${base}.xlsx`, planilhaDoAvaliador(av, linhas));
  writeFileSync(`${PASTA}/${base}.html`, paginaDoAvaliador(av, linhas), 'utf8');
  pacotes.push({ av, linhas, arquivo: base });
}

const comLeads = pacotes.filter(p => p.arquivo);

/* Quem não salvou nada se divide em dois grupos com significados
   opostos. Um representante de universidade sem nenhum contato é
   notícia: ou o app não foi usado, ou alguém não conseguiu entrar
   no dia. Já supervisor, gestor e equipe de palestras nunca
   escaneiam aluno — a conta existe para credenciar e para o
   painel. Listar os dois juntos afogaria os primeiros no meio dos
   segundos. */
const semLeads = pacotes.filter(p => !p.arquivo && p.av.papel === 'avaliador');
const equipe   = pacotes.filter(p => !p.arquivo && p.av.papel !== 'avaliador');
const totalLeads = comLeads.reduce((s, p) => s + p.linhas.length, 0);
const alunosAlcancados = new Set(
  comLeads.flatMap(p => p.linhas.map(l => l.codigo))).size;

/* Os pacotes do patrocinador, quando pedidos. Nome de arquivo com
   prefixo próprio: numa pasta de 33 planilhas de universidade,
   estes são os arquivos que não podem ser anexados no e-mail
   errado. */
const basePatrocinador = PATROCINADOR ? 'patrocinador-' + apelido(PATROCINADOR) : null;
const gerados = [];

if (PATROCINADOR && PACOTES.has('presentes')) {
  const linhas = emOrdem(naFeira);

  writeFileSync(`${PASTA}/${basePatrocinador}.xlsx`,
    /* Travessão, não barra: o Excel proíbe / em nome de aba. */
    montarXlsx([{ nome: 'Alunos da feira – Students', colunas: COLUNAS_PATROCINADOR, linhas }]));
  writeFileSync(`${PASTA}/${basePatrocinador}.html`,
    paginaDoPatrocinador(linhas), 'utf8');

  gerados.push({
    arquivo: basePatrocinador,
    titulo: 'Alunos que estiveram na feira',
    detalhe: `${linhas.length} aluno(s) · uma aba`,
    html: true
  });
}

if (PATROCINADOR && PACOTES.has('representantes')) {
  const arquivo = `${basePatrocinador}-representantes`;

  /* Aba de rosto primeiro, depois uma por pessoa. Quem não leu
     nada aparece no resumo com zero e sem aba. */
  const resumo = daOrganizacao.map(r => ({
    nome: r.av.nome,
    email: r.av.email,
    lidos: r.lidos,
    salvos: r.linhas.length,
    aba: r.linhas.length ? r.av.nome : 'sem aba — não leu nenhum crachá'
  }));

  const abas = [
    { nome: 'Resumo – Summary', colunas: COLUNAS_RESUMO, linhas: resumo },
    ...comLeitura.map(r => ({ nome: r.av.nome, colunas: COLUNAS, linhas: r.linhas }))
  ];

  writeFileSync(`${PASTA}/${arquivo}.xlsx`, montarXlsx(abas));

  gerados.push({
    arquivo,
    titulo: `Leituras de cada pessoa da ${ORG}`,
    detalhe: `${comLeitura.length} aba(s) de pessoa + resumo · ` +
             `${comLeitura.reduce((s, r) => s + r.linhas.length, 0)} contato(s)`,
    html: false
  });
}

if (PATROCINADOR && PACOTES.has('inscritos')) {
  const arquivo = `${basePatrocinador}-inscritos`;

  writeFileSync(`${PASTA}/${arquivo}.xlsx`, montarXlsx([
    { nome: 'Alunos – Students',      colunas: COLUNAS_PATROCINADOR,  linhas: alunosInscritos },
    { nome: 'Responsáveis – Guardians', colunas: COLUNAS_RESPONSAVEIS, linhas: responsaveisInscritos }
  ]));

  gerados.push({
    arquivo,
    titulo: 'Todos os inscritos no evento',
    detalhe: `${alunosInscritos.length} aluno(s) e ` +
             `${responsaveisInscritos.length} responsável(is) · duas abas · ` +
             'inclui quem não compareceu',
    html: false
  });
}

const agora = new Date().toLocaleString('pt-BR');

const indice = `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Envio dos leads — Alfa University Fair</title>
<style>${ESTILO}</style>
</head>
<body>
<div class="env">

<header>
  <h1>Envio dos leads · Alfa University Fair</h1>
  <div class="sub">Foto de ${agora} · ${comLeads.length} avaliador(es) com contato ·
    ${totalLeads} lead(s) · ${alunosAlcancados} aluno(s) alcançado(s)</div>
</header>

<p class="aviso"><b>Esta pasta tem nome, e-mail e telefone de menores de idade.</b>
Não publique, não suba para o Drive e apague depois do envio. Rodar
<code>node scripts/leads-avaliadores.mjs</code> de novo regenera tudo.</p>

${gerados.length ? `
<section>
  <h2>Pacote do patrocinador — ${esc(PATROCINADOR)}</h2>
  <table>
    <tr><th>Planilha</th><th>Conteúdo</th><th>Arquivo</th></tr>
    ${gerados.map(g => `<tr>
      <td>${esc(g.titulo)}</td>
      <td class="obs">${esc(g.detalhe)}</td>
      <td><a href="${esc(g.arquivo)}.xlsx">${esc(g.arquivo)}.xlsx</a>${
        g.html ? ` · <a href="${esc(g.arquivo)}.html">.html</a>` : ''}</td>
    </tr>`).join('')}
  </table>
  <p class="obs">Nenhuma delas traz nota ou comentário de representante de
  outra universidade. No arquivo por pessoa da ${esc(ORG || PATROCINADOR)} as
  duas colunas aparecem, porque ali quem escreveu foi a própria equipe.
  ${naFeiraSemAutorizacao.length ? `Ficaram de fora ${naFeiraSemAutorizacao.length}
  aluno(s) que hoje não autorizam compartilhamento.` : ''}</p>
  <p class="obs"><b>Estes são os arquivos que não podem ir no e-mail errado.</b>
  São os únicos da pasta que não pertencem a um representante de universidade.</p>
</section>` : ''}

${pesquisa ? `
<section>
  <h2>Pesquisa de feedback — link geral</h2>
  <p style="font-size:17px;margin:0 0 10px">
    ${SITE
      ? `<a href="${esc(SITE)}/${esc(PAGINA)}#${esc(comHifen(pesquisa.codigo))}"><b>${
          esc(SITE)}/${esc(PAGINA)}#${esc(comHifen(pesquisa.codigo))}</b></a>`
      : `<b>#${esc(comHifen(pesquisa.codigo))}</b> — rode com <code>--site https://seu-dominio</code>`}
  </p>
  <p class="obs">${pesquisa.aberta
    ? 'Aberta. É o mesmo endereço para todo mundo: vai no e-mail, no grupo, no slide.'
    : '<b>ENCERRADA</b> — quem abrir vê aviso de prazo encerrado. Para reabrir: ' +
      '<code>update pesquisa_evento set aberta = true;</code>'}
    Como ninguém é identificado, não há lista de quem falta responder.</p>
</section>` : ''}

<section>
  <h2>Um e-mail por linha</h2>
  <table>
    <tr><th>Avaliador</th><th>Organização</th><th>Para</th><th>Leads</th><th>Anexos</th>
      ${temPesquisa ? '<th>Link da pesquisa</th>' : ''}</tr>
    ${comLeads.map(p => `<tr>
      <td>${esc(p.av.nome)}</td>
      <td>${esc(p.av.organizacao || '—')}</td>
      <td>${esc(p.av.email)}</td>
      <td class="nota">${p.linhas.length}</td>
      <td><a href="${esc(p.arquivo)}.xlsx">${esc(p.arquivo)}.xlsx</a> ·
          <a href="${esc(p.arquivo)}.html">.html</a></td>
      ${temPesquisa ? `<td class="obs">${
        p.av.avaliacao_token
          ? (SITE ? (l => `<a href="${esc(l)}">${esc(l)}</a>`)(
                      `${SITE}/${PAGINA}#${comHifen(p.av.avaliacao_token)}`)
                  : '#' + esc(comHifen(p.av.avaliacao_token)) +
                    ' <b>(rode com --site https://seu-dominio)</b>')
          : '—'}</td>` : ''}
    </tr>`).join('')}
  </table>
  ${temPesquisa
    ? `<p class="obs">O link da pesquisa é <b>único por pessoa</b> — ele é o que
       identifica quem respondeu. Cada um recebe o seu; encaminhar o e-mail
       entrega a vez de responder a outra pessoa.</p>`
    : `<p class="obs">A pesquisa de feedback ainda não está no banco: aplique a
       migration <code>0049_avaliacao_evento.sql</code> para os links aparecerem aqui.</p>`}
</section>

<section>
  <h2>Modelo de e-mail</h2>
  <p class="obs">Anexe a planilha do avaliador. O HTML é opcional — serve para
  quem prefere só ler a lista.</p>
  <p class="obs">A maior parte dos representantes é de universidade estrangeira:
  o modelo em inglês está logo abaixo do português.</p>
  <table>
    <tr><td>
      <b>Assunto:</b> Seus contatos da Alfa University Fair<br><br>
      Olá, [NOME],<br><br>
      Obrigado pela participação na Alfa University Fair.
      Em anexo está a planilha com os [N] contatos que você registrou no
      aplicativo durante o evento.<br><br>
      Os dados foram compartilhados com autorização do responsável, para
      contato posterior sobre oportunidades acadêmicas. Pedimos que sejam
      usados apenas para essa finalidade e não repassados a terceiros.
      Para pedir a exclusão de algum registro, basta responder a este e-mail.<br><br>
      Se puder, responda também nossa pesquisa de feedback — leva 2 minutos e o
      link é o da coluna "Link da pesquisa" desta linha. <b>Cole o link atrás de
      um texto clicável</b> (por exemplo: <u>Responder a pesquisa</u>) em vez de
      deixar o endereço à mostra.<br><br>
      Abraço,<br>
      [SEU NOME]
    </td></tr>
    <tr><td>
      <b>Subject:</b> Your contacts from Alfa University Fair<br><br>
      Dear [NAME],<br><br>
      Thank you for taking part in Alfa University Fair.
      Attached is the spreadsheet with the [N] contacts you registered in the
      app during the event. Column headings are in Portuguese and English;
      the students' answers are in Portuguese.<br><br>
      This data was shared with the legal guardian's consent, for follow-up
      contact about academic opportunities. We ask that it be used for that
      purpose only and not shared with third parties. To request removal of
      any record, simply reply to this email.<br><br>
      We would also appreciate your feedback on the fair — it takes 2 minutes,
      and the link is personal to you.<br><br>
      Best regards,<br>
      [YOUR NAME]
    </td></tr>
  </table>
</section>

${semLeads.length ? `
<section>
  <h2>Representantes sem nenhum contato salvo — não recebem e-mail</h2>
  <p class="obs">Estavam cadastrados como avaliadores e não registraram ninguém.
  Vale conferir se o aplicativo chegou a ser usado por eles no dia.</p>
  <table>
    <tr><th>Avaliador</th><th>Organização</th><th>E-mail</th></tr>
    ${semLeads.map(p => `<tr>
      <td>${esc(p.av.nome)}</td>
      <td>${esc(p.av.organizacao || '—')}</td>
      <td>${esc(p.av.email)}</td>
    </tr>`).join('')}
  </table>
</section>` : ''}

${equipe.length ? `
<section>
  <h2>Contas de equipe — fora do envio por definição</h2>
  <p class="obs">${equipe.length} conta(s) de supervisão, gestão, diretoria e
  palestras. Existem para credenciar e para o painel; não escaneiam aluno e
  não têm lead a receber.</p>
</section>` : ''}

${revogados.length ? `
<section>
  <h2>Registros retirados da exportação</h2>
  <p class="obs">${revogados.length} contato(s) de aluno(s) que hoje não têm
  autorização de compartilhamento — consentimento revogado ou nível zerado
  depois do evento. Continuam no banco; apenas não são distribuídos.</p>
  <table>
    <tr><th>Aluno</th><th>Código</th></tr>
    ${revogados.map(r => `<tr>
      <td>${esc(r.a.nome)}</td><td>${esc(r.a.codigo_curto)}</td>
    </tr>`).join('')}
  </table>
</section>` : ''}

</div>
</body>
</html>
`;

writeFileSync(`${PASTA}/indice.html`, indice, 'utf8');

/* ------------------------------------------------------------
   Resumo no terminal
   ------------------------------------------------------------ */
console.log(`${totalLeads} lead(s) de ${alunosAlcancados} aluno(s), ` +
            `em ${comLeads.length} pacote(s), na pasta ${PASTA}/`);
if (semLeads.length) {
  console.log(`  ${semLeads.length} representante(s) não salvaram nada e ficaram de fora.`);
}
if (equipe.length) {
  console.log(`  ${equipe.length} conta(s) de equipe (supervisão, gestão, palestras) não entram no envio.`);
}
if (gerados.length) {
  console.log(`\nPatrocinador "${PATROCINADOR}":`);
  for (const g of gerados) console.log(`  ${g.arquivo}.xlsx — ${g.detalhe}`);

  if (PACOTES.has('representantes')) {
    const sem = daOrganizacao.length - comLeitura.length;
    if (!daOrganizacao.length) {
      console.log(`  ATENÇÃO: nenhum avaliador com organizacao = "${ORG}". Confira o nome.`);
    } else if (sem > 0) {
      console.log(`  ${sem} pessoa(s) da ${ORG} sem aba: não leram nenhum crachá (aparecem no resumo).`);
    }
  }
  if (naFeiraSemAutorizacao.length) {
    console.log(`  ${naFeiraSemAutorizacao.length} aluno(s) fora das listas: não autorizam compartilhamento.`);
  }
} else {
  console.log('\nPacote do patrocinador não foi gerado. Para gerar:');
  console.log('  node scripts/leads-avaliadores.mjs --patrocinador "IE" \\');
  console.log('       --pacote presentes,representantes,inscritos');
}
if (revogados.length) {
  console.log(`  ${revogados.length} contato(s) retirado(s): o aluno não autoriza mais.`);
}
if (semAluno.length) {
  console.log(`  ATENÇÃO: ${semAluno.length} contato(s) apontam para aluno inexistente.`);
}
console.log('\nAbra ' + PASTA + '/indice.html: tem a lista de envio e o modelo de e-mail.');
console.log('Contém dado pessoal de menores: não publique e apague depois do envio.');
