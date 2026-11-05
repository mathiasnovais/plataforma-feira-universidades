/* ============================================================
   Importação dos alunos a partir da planilha (feira local)

   Na feira local não há autoinscrição: a escola já sabe quem vai.
   Este script lê a planilha (.xlsx ou .csv) e cria os alunos no
   banco. `cracha_token` e `codigo_curto` nascem sozinhos no
   banco — depois é só gerar os crachás.

   Sem npm install. O .xlsx é um zip de XML, e o Node já traz o
   zip — mesmo princípio do xlsx.mjs, que escreve; este lê.

   USO (PowerShell, com segredo-supabase.txt na raiz):
     node scripts/importar-alunos.mjs alunos.xlsx               # ensaio
     node scripts/importar-alunos.mjs alunos.xlsx --executar    # grava

   O ENSAIO É O PADRÃO. Sem --executar o script só mostra como
   entendeu a planilha: qual coluna virou qual campo, quantas
   linhas entram, o que será ignorado. Importação com coluna
   trocada é silenciosa e aparece só no dia do evento — o ensaio
   existe para ela aparecer agora.

   COLUNAS RECONHECIDAS (a ordem não importa, maiúsculas e
   acentos também não):
     nome*                       nome / nome completo / aluno
     ano_escolaridade            ano / série / turma / escolaridade
     unidade                     unidade / escola / colégio / campus
     email                       email / e-mail do aluno
     telefone                    telefone / celular
     responsavel_nome            responsável / nome do responsável
     responsavel_email           email do responsável
     responsavel_telefone        telefone do responsável
   * obrigatória. Coluna fora da lista é ignorada e avisada.

   CONSENTIMENTO — leia antes de rodar

   Por padrão cada aluno entra com nivel_compartilhamento = 3 e
   consentimento_responsavel = true, marcando a versão
   'importacao-<data>'. Isso diz ao sistema que A ESCOLA JÁ TEM a
   autorização dos responsáveis para compartilhar o contato com as
   universidades (sem isso o app não mostra nem salva nada — é a
   regra da plataforma, não deste script). Se essa autorização
   ainda não existe, rode com --sem-consentimento: os alunos
   entram, os crachás saem, a presença funciona, mas nenhum dado
   de contato é exibido ou exportado até o consentimento ser
   registrado no banco.

   Idempotente por nome: quem já existe (mesmo nome, ignorando
   caixa e acento) não entra de novo — rodar duas vezes não
   duplica. Homônimos verdadeiros: ajuste o nome na planilha
   (ex.: acrescente o ano) ou cadastre pelo evento.html.
   ============================================================ */

import { readFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import { exigirChave, exigirUrl } from './chave.mjs';

const URL_PROJETO = exigirUrl();
const argumentos = process.argv.slice(2);
const EXECUTAR = argumentos.includes('--executar');
const SEM_CONSENTIMENTO = argumentos.includes('--sem-consentimento');
const ARQUIVO = argumentos.find(a => !a.startsWith('--'));

if (!ARQUIVO) {
  console.error('Uso: node scripts/importar-alunos.mjs planilha.xlsx [--executar] [--sem-consentimento]');
  process.exit(1);
}

const CHAVE = exigirChave();
const cabecalhos = {
  apikey: CHAVE,
  Authorization: 'Bearer ' + CHAVE,
  'Content-Type': 'application/json'
};

/* ============================================================
   LEITURA DO .XLSX

   Um .xlsx é um zip. Aqui só interessam três arquivos de dentro:
   a primeira planilha, o dicionário de textos (sharedStrings) e
   nada mais. O parse de XML é por regex de propósito: o XML que o
   Excel escreve é regular o bastante, e uma dependência de parser
   custaria o npm install que este projeto evita.
   ============================================================ */
function abrirZip(buf) {
  // End of Central Directory: assinatura 0x06054b50, procurada do
  // fim para trás (o comentário do zip pode empurrá-la).
  let eocd = -1;
  const limite = Math.max(0, buf.length - 22 - 65536);
  for (let i = buf.length - 22; i >= limite; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('o arquivo não parece um .xlsx válido');

  const total = buf.readUInt16LE(eocd + 10);
  let pos = buf.readUInt32LE(eocd + 16);
  const indice = new Map();

  for (let n = 0; n < total; n++) {
    if (buf.readUInt32LE(pos) !== 0x02014b50) break;
    const metodo    = buf.readUInt16LE(pos + 10);
    const tamanho   = buf.readUInt32LE(pos + 20);  // comprimido
    const nomeLen   = buf.readUInt16LE(pos + 28);
    const extraLen  = buf.readUInt16LE(pos + 30);
    const comentLen = buf.readUInt16LE(pos + 32);
    const offset    = buf.readUInt32LE(pos + 42);
    const nome = buf.toString('utf8', pos + 46, pos + 46 + nomeLen);
    indice.set(nome, { metodo, tamanho, offset });
    pos += 46 + nomeLen + extraLen + comentLen;
  }

  return nome => {
    const f = indice.get(nome);
    if (!f) return null;
    // O cabeçalho local repete nome e extra com comprimentos
    // próprios (o extra costuma diferir do central).
    const nomeLen  = buf.readUInt16LE(f.offset + 26);
    const extraLen = buf.readUInt16LE(f.offset + 28);
    const inicio = f.offset + 30 + nomeLen + extraLen;
    const dados = buf.subarray(inicio, inicio + f.tamanho);
    return (f.metodo === 8 ? inflateRawSync(dados) : Buffer.from(dados)).toString('utf8');
  };
}

const decodificar = t => String(t)
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
  .replace(/&apos;/g, "'").replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
  .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(+d))
  .replace(/&amp;/g, '&');

function textosCompartilhados(xml) {
  const out = [];
  if (!xml) return out;
  const re = /<si(?:\s[^>]*)?>([\s\S]*?)<\/si>/g;
  for (let m; (m = re.exec(xml)); ) {
    // Um <si> pode ter vários <t> (texto com formatação por trecho).
    let texto = '';
    const tre = /<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g;
    for (let t; (t = tre.exec(m[1])); ) texto += decodificar(t[1]);
    out.push(texto);
  }
  return out;
}

const colunaParaIndice = letras => {
  let n = 0;
  for (const ch of letras) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
};

function lerXlsx(caminho) {
  const zip = abrirZip(readFileSync(caminho));
  const strings = textosCompartilhados(zip('xl/sharedStrings.xml'));

  // A primeira aba na prática é sheet1.xml; se o arquivo veio de
  // outra ferramenta, pega a de menor número.
  let xml = zip('xl/worksheets/sheet1.xml');
  if (!xml) {
    for (let n = 2; n <= 20 && !xml; n++) xml = zip(`xl/worksheets/sheet${n}.xml`);
  }
  if (!xml) throw new Error('não achei nenhuma aba dentro do .xlsx');

  const linhas = [];
  const rowRe = /<row[^>]*?>([\s\S]*?)<\/row>/g;
  for (let r; (r = rowRe.exec(xml)); ) {
    const celulas = [];
    let seq = 0;
    const celRe = /<c(\s[^>]*?)?(?:\/>|>([\s\S]*?)<\/c>)/g;
    for (let c; (c = celRe.exec(r[1])); ) {
      const attrs = c[1] || '';
      const corpo = c[2] || '';
      const ref = attrs.match(/\br="([A-Z]+)\d+"/);
      const idx = ref ? colunaParaIndice(ref[1]) : seq;
      seq = idx + 1;

      const tipo = (attrs.match(/\bt="([^"]+)"/) || [])[1] || '';
      let valor = '';
      if (tipo === 'inlineStr') {
        const t = corpo.match(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/);
        valor = t ? decodificar(t[1]) : '';
      } else {
        const v = corpo.match(/<v>([\s\S]*?)<\/v>/);
        if (v) valor = tipo === 's' ? (strings[+v[1]] ?? '') : decodificar(v[1]);
      }
      celulas[idx] = String(valor).trim();
    }
    linhas.push(celulas);
  }
  return linhas;
}

/* ---- CSV, caso a planilha venha exportada ----
   O Excel brasileiro exporta com ponto e vírgula; o separador é
   deduzido do cabeçalho. Aspas duplas escapadas ("" dentro de
   campo) são respeitadas. */
function lerCsv(caminho) {
  const texto = readFileSync(caminho, 'utf8').replace(/^﻿/, '');
  const linhasBrutas = texto.replace(/\r\n?/g, '\n').split('\n').filter(l => l.trim());
  if (!linhasBrutas.length) return [];
  const sep = (linhasBrutas[0].match(/;/g) || []).length >
              (linhasBrutas[0].match(/,/g) || []).length ? ';' : ',';

  return linhasBrutas.map(linha => {
    const campos = [];
    let atual = '', aspas = false;
    for (let i = 0; i < linha.length; i++) {
      const ch = linha[i];
      if (ch === '"') {
        if (aspas && linha[i + 1] === '"') { atual += '"'; i++; }
        else aspas = !aspas;
      } else if (ch === sep && !aspas) { campos.push(atual.trim()); atual = ''; }
      else atual += ch;
    }
    campos.push(atual.trim());
    return campos;
  });
}

/* ============================================================
   DO CABEÇALHO DA PLANILHA PARA AS COLUNAS DO BANCO
   ============================================================ */
const normalizar = t => String(t || '').toLowerCase()
  .normalize('NFD').replace(/\p{M}/gu, '').replace(/[^a-z0-9]/g, '');

const MAPA = [
  [/^(nomecompleto|nomedoaluno|nomealuno|aluno|nome)$/,                'nome'],
  [/^(anoescolaridade|anodeescolaridade|escolaridade|anoserie|serie|ano|turma)$/, 'ano_escolaridade'],
  [/^(unidade|escola|colegio|campus)$/,                                'unidade'],
  [/^(email|emaildoaluno|emailaluno)$/,                                'email'],
  [/^(telefone|celular|telefonedoaluno|celulardoaluno)$/,              'telefone'],
  [/^(responsavel|nomedoresponsavel|nomeresponsavel|responsavelnome)$/,'responsavel_nome'],
  [/^(emaildoresponsavel|emailresponsavel|responsavelemail)$/,         'responsavel_email'],
  [/^(telefonedoresponsavel|telefoneresponsavel|celulardoresponsavel|celularresponsavel|responsaveltelefone)$/, 'responsavel_telefone'],
];

/* Export de secretaria vem com TODO MUNDO — inclusive quem já
   saiu da escola. Se a planilha tiver coluna de situação ou de
   contrato, quem bate nos padrões abaixo fica de fora, e o ensaio
   lista um por um para conferência. */
const FILTROS_STATUS = [
  ['situacao', /transferid|cancelad|inativ|desistente|trancad|evadid/i],
  ['status',   /transferid|cancelad|inativ|desistente|trancad|evadid/i],
  ['contrato', /cancelad|encerrad|rescindid|inativ/i],
];

const campoDe = cabecalho => {
  const chave = normalizar(cabecalho);
  for (const [re, campo] of MAPA) if (re.test(chave)) return campo;
  return null;
};

/* ============================================================
   O TRABALHO
   ============================================================ */
const chaveNome = t => normalizar(t); // mesma ideia do chave_nome do banco

async function existentes() {
  const r = await fetch(`${URL_PROJETO}/rest/v1/alunos?select=nome&ativo=eq.true`, {
    headers: { ...cabecalhos, Range: '0-19999' }
  });
  if (!r.ok) throw new Error('Falha ao consultar os alunos atuais: ' + await r.text());
  const lista = await r.json();
  return new Set(lista.map(a => chaveNome(a.nome)));
}

async function principal() {
  const ehXlsx = /\.xlsx$/i.test(ARQUIVO);
  const linhas = ehXlsx ? lerXlsx(ARQUIVO) : lerCsv(ARQUIVO);
  if (linhas.length < 2) {
    console.error('A planilha precisa de um cabeçalho e pelo menos uma linha de dados.');
    process.exit(1);
  }

  // ---- cabeçalho ----
  const cabecalho = linhas[0];
  const colunas = [];       // índice -> campo do banco (ou null)
  const ignoradas = [];
  const statusCols = [];    // [índice, regex de exclusão, título]
  const usados = new Map(); // campo -> título que já o ocupou
  cabecalho.forEach((titulo, i) => {
    const t = String(titulo || '').trim();
    if (!t) return;

    const filtro = FILTROS_STATUS.find(([chave]) => normalizar(t) === chave);
    if (filtro) { statusCols.push([i, filtro[1], t]); colunas[i] = null; return; }

    const campo = campoDe(t);
    /* Duas colunas para o mesmo campo (ex.: Série e Turma):
       a PRIMEIRA vence — sobrescrever em silêncio foi o que
       trocava a série pela turma. */
    if (campo && usados.has(campo)) { colunas[i] = null; ignoradas.push(`${t} (campo já veio de "${usados.get(campo)}")`); return; }
    if (campo) usados.set(campo, t);
    colunas[i] = campo;
    if (!campo) ignoradas.push(t);
  });

  console.log('Como a planilha foi entendida:');
  cabecalho.forEach((titulo, i) => {
    const t = String(titulo || '').trim();
    if (!t) return;
    const st = statusCols.find(([idx]) => idx === i);
    console.log(`  ${t.padEnd(32)} -> ${st ? '(filtro de situação)' : colunas[i] || '(ignorada)'}`);
  });
  if (!colunas.includes('nome')) {
    console.error('\nNenhuma coluna virou "nome" — sem ela não há o que importar.');
    console.error('Renomeie a coluna do nome na planilha para "Nome" e rode de novo.');
    process.exit(1);
  }

  // ---- linhas ----
  const agora = new Date().toISOString();
  const versaoConsent = 'importacao-' + agora.slice(0, 10);
  const vistos = new Set();
  const semNome = [];
  const duplicadasNaPlanilha = [];
  const foraPorStatus = [];
  const candidatos = [];

  for (let n = 1; n < linhas.length; n++) {
    const bruto = {};
    (linhas[n] || []).forEach((valor, i) => {
      if (colunas[i]) bruto[colunas[i]] = String(valor ?? '').trim();
    });

    const nome = bruto.nome || '';
    if (!nome) {
      if ((linhas[n] || []).some(v => String(v || '').trim())) semNome.push(n + 1);
      continue;
    }

    const barrado = statusCols.find(([i, re]) => re.test(String((linhas[n] || [])[i] || '')));
    if (barrado) {
      foraPorStatus.push(`${nome} (${barrado[2]}: ${(linhas[n] || [])[barrado[0]]})`);
      continue;
    }
    const chave = chaveNome(nome);
    if (vistos.has(chave)) { duplicadasNaPlanilha.push(nome); continue; }
    vistos.add(chave);

    candidatos.push({
      tipo: 'aluno',
      nome,
      aluno_alfacem: true,
      unidade: bruto.unidade || null,
      ano_escolaridade: bruto.ano_escolaridade || null,
      email: (bruto.email || '').toLowerCase() || null,
      telefone: bruto.telefone || null,
      responsavel_nome: bruto.responsavel_nome || null,
      responsavel_email: (bruto.responsavel_email || '').toLowerCase() || null,
      responsavel_telefone: bruto.responsavel_telefone || null,

      nivel_compartilhamento: SEM_CONSENTIMENTO ? 0 : 3,
      consentimento_responsavel: !SEM_CONSENTIMENTO,
      consentimento_versao: SEM_CONSENTIMENTO ? null : versaoConsent,
      consentimento_em: SEM_CONSENTIMENTO ? null : agora,
      ciencia_compartilhamento: !SEM_CONSENTIMENTO,

      origem: 'importacao',
      ativo: true,
      // Fora da fila de e-mail de confirmação (0022): importado
      // pela escola não recebe "inscrição confirmada".
      email_confirmacao_em: agora
    });
  }

  // ---- quem já está no banco ----
  const jaExistem = await existentes();
  const novos = candidatos.filter(c => !jaExistem.has(chaveNome(c.nome)));
  const repetidos = candidatos.length - novos.length;

  console.log('');
  console.log(`Linhas com dados: ${candidatos.length + semNome.length + duplicadasNaPlanilha.length + foraPorStatus.length}`);
  if (foraPorStatus.length) {
    console.log(`  fora pela situação/contrato (${foraPorStatus.length}):`);
    for (const f of foraPorStatus) console.log(`    ${f}`);
  }
  if (semNome.length) console.log(`  sem nome (puladas): linhas ${semNome.join(', ')}`);
  if (duplicadasNaPlanilha.length)
    console.log(`  repetidas na própria planilha (puladas): ${duplicadasNaPlanilha.join(' · ')}`);
  if (repetidos) console.log(`  já existem no banco (puladas): ${repetidos}`);
  if (ignoradas.length) console.log(`  colunas ignoradas: ${ignoradas.join(' · ')}`);
  console.log(`Entrariam agora: ${novos.length} aluno(s)`);
  console.log(SEM_CONSENTIMENTO
    ? 'Consentimento: NÃO marcado — crachá e presença funcionam, contato não aparece.'
    : `Consentimento: marcado como "${versaoConsent}" — confirme que a escola tem a autorização dos responsáveis.`);

  if (novos.length) {
    console.log('\nAmostra:');
    for (const c of novos.slice(0, 5)) {
      console.log(`  ${c.nome}` +
        (c.ano_escolaridade ? ` · ${c.ano_escolaridade}` : '') +
        (c.unidade ? ` · ${c.unidade}` : '') +
        (c.responsavel_email ? ` · resp: ${c.responsavel_email}` : ''));
    }
  }

  if (!EXECUTAR) {
    console.log('\nEnsaio — nada foi gravado. Se o mapa acima está certo, repita com --executar.');
    return;
  }
  if (!novos.length) {
    console.log('\nNada novo para gravar.');
    return;
  }

  // ---- gravação em lotes ----
  let gravados = 0;
  for (let i = 0; i < novos.length; i += 200) {
    const lote = novos.slice(i, i + 200);
    const r = await fetch(`${URL_PROJETO}/rest/v1/alunos`, {
      method: 'POST',
      headers: { ...cabecalhos, Prefer: 'return=minimal' },
      body: JSON.stringify(lote)
    });
    if (!r.ok) {
      console.error(`\nFalha no lote ${i / 200 + 1}: ` + await r.text());
      console.error(`Gravados até aqui: ${gravados}. Rodar de novo é seguro — quem entrou não duplica.`);
      process.exit(1);
    }
    gravados += lote.length;
    console.log(`  gravados ${gravados} de ${novos.length}…`);
  }

  console.log(`\nPronto: ${gravados} aluno(s) no banco, cada um com token e código de crachá.`);
  console.log('Próximo passo: node scripts/gerar-crachas.mjs https://SEU-DOMINIO');
}

principal().catch(e => { console.error('Erro: ' + (e.message || e)); process.exit(1); });
