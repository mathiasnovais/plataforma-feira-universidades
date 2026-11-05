/* ============================================================
   Um .xlsx de verdade, sem instalar nada

   O projeto não tem package.json e não vai ter: os scripts rodam
   com `node scripts/x.mjs` numa máquina qualquer, sem npm install
   e sem node_modules para versionar. No navegador o painel resolve
   isso puxando a biblioteca de uma CDN no clique — aqui não há
   navegador, e uma dependência instalada seria o primeiro
   node_modules do repositório.

   Acontece que um .xlsx é um zip com meia dúzia de arquivos XML
   dentro, e o Node já traz zlib com deflate e crc32. Então o
   gerador cabe neste arquivo.

   O QUE SAI PRONTO NA PLANILHA

   Cabeçalho em negrito e congelado (rolar 70 linhas sem perder o
   título), filtro no cabeçalho, largura de coluna medida no
   conteúdo, número que é número e data que é data — dá para
   ordenar por "salvo em" e a ordem sai cronológica, não
   alfabética.

   O congelamento é justamente o que a versão community da
   biblioteca do painel não conseguia escrever (veja o comentário
   em painel.html). Escrevendo o XML na mão, é uma linha.

   INJEÇÃO DE FÓRMULA

   No CSV, célula começada por = + - @ vira fórmula e por isso o
   painel põe uma aspa na frente. Aqui não é preciso: cada célula
   de texto sai marcada como `inlineStr`, e o Excel não interpreta
   fórmula em string inline. O dado chega limpo, do jeito que a
   pessoa escreveu.

   USO

     montarXlsx([{
       nome: 'Contatos',
       colunas: [{ titulo: 'Nome', chave: 'nome' },
                 { titulo: 'Nota', chave: 'nota', tipo: 'numero' },
                 { titulo: 'Salvo em', chave: 'salvo_em', tipo: 'data' }],
       linhas: [{ nome: 'Ana', nota: 5, salvo_em: '22/08/2026 10:52' }]
     }])  ->  Buffer, pronto para writeFileSync
   ============================================================ */

import { deflateRawSync, crc32 } from 'node:zlib';

/* ------------------------------------------------------------
   XML
   ------------------------------------------------------------ */

/* Além dos cinco caracteres de sempre, tira os caracteres de
   controle: um \x01 vindo de copiar-e-colar num comentário faz o
   Excel recusar o arquivo inteiro com "conteúdo ilegível", sem
   dizer onde. */
const esc = t => String(t == null ? '' : t)
  .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&apos;');

/* 1 -> A, 27 -> AA. Coluna de planilha é base 26 sem o zero. */
function letraDaColuna(n) {
  let s = '';
  while (n > 0) {
    const resto = (n - 1) % 26;
    s = String.fromCharCode(65 + resto) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

/* Data em número de série do Excel: dias desde 30/12/1899, com a
   fração do dia nas horas. Recebe "DD/MM/AAAA HH:MM" — o formato
   que os scripts já produzem em horário de Brasília — e trata como
   hora local da planilha, sem fuso: quem abrir o arquivo em Lisboa
   tem de ver o mesmo horário que quem abriu no Rio. */
function serieDeData(txt) {
  const m = /^(\d{2})\/(\d{2})\/(\d{4})[ T](\d{2}):(\d{2})/.exec(String(txt || ''));
  if (!m) return null;
  const [, d, mes, ano, h, min] = m.map(Number);

  const dias = Math.floor(Date.UTC(ano, mes - 1, d) / 86400000) + 25569;
  return dias + (h * 60 + min) / 1440;
}

function celula(ref, valor, tipo) {
  if (valor === null || valor === undefined || valor === '') return '';

  if (tipo === 'numero') {
    const n = Number(valor);
    if (!Number.isFinite(n)) return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${esc(valor)}</t></is></c>`;
    return `<c r="${ref}"><v>${n}</v></c>`;
  }

  if (tipo === 'data') {
    const s = serieDeData(valor);
    /* Data que não casa com o formato esperado sai como texto em
       vez de sumir. Planilha pior é melhor que dado perdido. */
    if (s === null) return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${esc(valor)}</t></is></c>`;
    return `<c r="${ref}" s="2"><v>${s}</v></c>`;
  }

  return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${esc(valor)}</t></is></c>`;
}

function planilha(aba) {
  const { colunas, linhas } = aba;
  const ultima = letraDaColuna(colunas.length);
  const faixa = `A1:${ultima}${linhas.length + 1}`;

  /* Largura medida no conteúdo real. Sem isto tudo sai com 8
     caracteres e a primeira coisa que a pessoa faz é arrastar 19
     divisórias. O teto de 46 evita que um comentário longo estique
     a coluna até empurrar o resto para fora da tela. */
  const larguras = colunas.map((col, i) => {
    let maior = String(col.titulo).length;
    for (const l of linhas) {
      const v = l[col.chave];
      const n = col.tipo === 'data' ? 16 : String(v == null ? '' : v).length;
      if (n > maior) maior = n;
    }
    return `<col min="${i + 1}" max="${i + 1}" width="${Math.min(maior + 2, 46)}" customWidth="1"/>`;
  }).join('');

  const cabecalho = colunas
    .map((c, i) => `<c r="${letraDaColuna(i + 1)}1" t="inlineStr" s="1"><is><t>${esc(c.titulo)}</t></is></c>`)
    .join('');

  const corpo = linhas.map((l, n) => {
    const linha = n + 2;
    const cels = colunas
      .map((c, i) => celula(`${letraDaColuna(i + 1)}${linha}`, l[c.chave], c.tipo))
      .join('');
    return `<row r="${linha}">${cels}</row>`;
  }).join('');

  /* A ordem dos elementos é imposta pelo schema: dimension,
     sheetViews, sheetFormatPr, cols, sheetData, autoFilter. Fora
     de ordem, o Excel recusa o arquivo. */
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<dimension ref="${faixa}"/>
<sheetViews><sheetView workbookViewId="0" tabSelected="1">
<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>
<selection pane="bottomLeft" activeCell="A2" sqref="A2"/>
</sheetView></sheetViews>
<sheetFormatPr defaultRowHeight="15"/>
<cols>${larguras}</cols>
<sheetData><row r="1">${cabecalho}</row>${corpo}</sheetData>
<autoFilter ref="${faixa}"/>
</worksheet>`;
}

/* Três estilos: 0 comum, 1 cabeçalho, 2 data. O fill cinza na
   posição 1 é exigência do formato — o Excel espera "none" e
   "gray125" nas duas primeiras posições e ignora quem as pula. */
const ESTILOS = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy hh:mm"/></numFmts>
<fonts count="2">
<font><sz val="11"/><name val="Calibri"/></font>
<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
</fonts>
<fills count="3">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF1478D0"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="3">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
</cellXfs>
</styleSheet>`;

/* ------------------------------------------------------------
   ZIP

   Só o necessário: sem zip64 (planilha de mil linhas não chega
   perto dos 4 GB) e sem senha. Deflate cru via zlib.
   ------------------------------------------------------------ */

/* Data fixa em vez da hora atual, de propósito: com carimbo de
   relógio, rodar o script duas vezes gera arquivos diferentes byte
   a byte para os mesmos dados, e não dá para saber se algo mudou
   comparando os arquivos. 01/01/2026, 00:00, em DOS. */
const DATA_DOS = ((2026 - 1980) << 9) | (1 << 5) | 1;
const HORA_DOS = 0;

function zipar(arquivos) {
  const locais = [];
  const central = [];
  let deslocamento = 0;

  for (const { nome, dados } of arquivos) {
    const cru = Buffer.from(dados, 'utf8');
    const comprimido = deflateRawSync(cru, { level: 9 });
    const soma = crc32(cru);
    const bytesNome = Buffer.from(nome, 'utf8');

    const cabecalho = Buffer.alloc(30);
    cabecalho.writeUInt32LE(0x04034b50, 0);   // assinatura
    cabecalho.writeUInt16LE(20, 4);           // versão necessária
    cabecalho.writeUInt16LE(0, 6);            // sem flags
    cabecalho.writeUInt16LE(8, 8);            // método: deflate
    cabecalho.writeUInt16LE(HORA_DOS, 10);
    cabecalho.writeUInt16LE(DATA_DOS, 12);
    cabecalho.writeUInt32LE(soma, 14);
    cabecalho.writeUInt32LE(comprimido.length, 18);
    cabecalho.writeUInt32LE(cru.length, 22);
    cabecalho.writeUInt16LE(bytesNome.length, 26);
    cabecalho.writeUInt16LE(0, 28);           // sem campo extra

    locais.push(cabecalho, bytesNome, comprimido);

    const entrada = Buffer.alloc(46);
    entrada.writeUInt32LE(0x02014b50, 0);
    entrada.writeUInt16LE(20, 4);             // versão de quem criou
    entrada.writeUInt16LE(20, 6);             // versão necessária
    entrada.writeUInt16LE(0, 8);
    entrada.writeUInt16LE(8, 10);
    entrada.writeUInt16LE(HORA_DOS, 12);
    entrada.writeUInt16LE(DATA_DOS, 14);
    entrada.writeUInt32LE(soma, 16);
    entrada.writeUInt32LE(comprimido.length, 20);
    entrada.writeUInt32LE(cru.length, 24);
    entrada.writeUInt16LE(bytesNome.length, 28);
    entrada.writeUInt16LE(0, 30);             // extra
    entrada.writeUInt16LE(0, 32);             // comentário
    entrada.writeUInt16LE(0, 34);             // disco
    entrada.writeUInt16LE(0, 36);             // atributos internos
    entrada.writeUInt32LE(0, 38);             // atributos externos
    entrada.writeUInt32LE(deslocamento, 42);  // onde começa o local

    central.push(entrada, bytesNome);

    deslocamento += cabecalho.length + bytesNome.length + comprimido.length;
  }

  const corpo = Buffer.concat(locais);
  const indice = Buffer.concat(central);

  const fim = Buffer.alloc(22);
  fim.writeUInt32LE(0x06054b50, 0);
  fim.writeUInt16LE(0, 4);                    // disco
  fim.writeUInt16LE(0, 6);                    // disco do índice
  fim.writeUInt16LE(arquivos.length, 8);
  fim.writeUInt16LE(arquivos.length, 10);
  fim.writeUInt32LE(indice.length, 12);
  fim.writeUInt32LE(corpo.length, 16);
  fim.writeUInt16LE(0, 20);                   // sem comentário

  return Buffer.concat([corpo, indice, fim]);
}

/* ------------------------------------------------------------
   Montagem do pacote
   ------------------------------------------------------------ */

/* O Excel trunca nome de aba em 31 caracteres e recusa : \ / ? * [ ]
   — e recusa o arquivo inteiro, não só a aba. Trocar o proibido por
   espaço deixaria "Alunos / Students" virar "Alunos   Students", com
   o buraco à vista; por isso os espaços repetidos são colapsados
   depois da troca. */
const nomeDeAba = (t, i) =>
  (String(t || '').replace(/[:\\\/?*\[\]]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 31))
  || `Planilha${i + 1}`;

/* O Excel recusa o arquivo inteiro se duas abas tiverem o mesmo
   nome — e o corte em 31 caracteres cria empates que não existiam
   na origem: "Maria Fernanda Albuquerque Cost(a)" e
   "...Cost(o)" viram a mesma coisa. O sufixo numérico entra dentro
   do limite, comendo o fim do nome em vez de estourá-lo. */
function nomesUnicos(abas) {
  const usados = new Set();

  return abas.map((a, i) => {
    const base = nomeDeAba(a.nome, i);
    if (!usados.has(base)) { usados.add(base); return base; }

    for (let n = 2; ; n++) {
      const sufixo = ' (' + n + ')';
      const tentativa = base.slice(0, 31 - sufixo.length) + sufixo;
      if (!usados.has(tentativa)) { usados.add(tentativa); return tentativa; }
    }
  });
}

export function montarXlsx(abas) {
  const nomes = nomesUnicos(abas);

  const arquivos = [
    {
      nome: '[Content_Types].xml',
      dados: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
${abas.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')}
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>`
    },
    {
      nome: '_rels/.rels',
      dados: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>`
    },
    {
      nome: 'xl/workbook.xml',
      dados: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>${nomes.map((n, i) => `<sheet name="${esc(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets>
</workbook>`
    },
    {
      nome: 'xl/_rels/workbook.xml.rels',
      dados: `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${abas.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')}
<Relationship Id="rId${abas.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>`
    },
    { nome: 'xl/styles.xml', dados: ESTILOS }
  ];

  abas.forEach((aba, i) => {
    arquivos.push({ nome: `xl/worksheets/sheet${i + 1}.xml`, dados: planilha(aba) });
  });

  return zipar(arquivos);
}
