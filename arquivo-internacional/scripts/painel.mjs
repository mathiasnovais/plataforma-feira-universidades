/* ============================================================
   Painel de acompanhamento das inscrições

   Lê o banco e escreve saida/painel.html — uma página estática,
   sem chave dentro, para abrir no navegador e olhar os números.

   USO (PowerShell):
     $env:SUPABASE_SERVICE_ROLE = "cole_a_service_role_aqui"
     node scripts/painel.mjs

   POR QUE ESTÁTICO, E NÃO UMA PÁGINA QUE CONSULTA SOZINHA

   Uma página que buscasse os dados ao vivo precisaria da chave
   dentro dela. A service_role ignora toda a RLS: num arquivo,
   ela vaza junto com o arquivo. Aqui a chave fica só na variável
   de ambiente do terminal, e o HTML sai com os números já
   calculados.

   O preço é ser uma fotografia: para atualizar, rode de novo.
   Para acompanhar inscrição que chega ao longo de semanas, é
   troca barata.

   ATENÇÃO: saida/painel.html tem nome e e-mail de menores de
   idade. Mesma regra do crachá — não publique, não suba para a
   hospedagem, apague quando não precisar mais.
   ============================================================ */

import { writeFileSync, mkdirSync } from 'node:fs';
import { exigirChave, exigirUrl } from './chave.mjs';

const URL_PROJETO = exigirUrl();
const CHAVE = exigirChave();

async function ler(caminho) {
  const r = await fetch(`${URL_PROJETO}/rest/v1/${caminho}`, {
    headers: { apikey: CHAVE, Authorization: 'Bearer ' + CHAVE }
  });
  if (!r.ok) {
    console.error(`Falha ao ler ${caminho}:`, await r.text());
    process.exit(1);
  }
  return r.json();
}

const alunos = await ler(
  'alunos?select=id,tipo,nome,ativo,criado_em,aluno_alfacem,unidade,colegio,segmento,' +
  'ano_escolaridade,paises_interesse,motivo,responsavel_nome,responsavel_email,email,' +
  'responsavel_acompanha,email_confirmacao_em&order=criado_em.desc'
);
const acomp = await ler('acompanhantes?select=id,aluno_id,nome,parentesco');

/* ---------------------------------------------------------- */

const esc = t => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const contar = (lista, chave) => {
  const m = new Map();
  for (const x of lista) {
    for (const v of [].concat(chave(x) ?? [])) {
      if (v == null || v === '') continue;
      m.set(v, (m.get(v) || 0) + 1);
    }
  }
  return [...m.entries()].sort((a, b) => b[1] - a[1]);
};

const estudantes = alunos.filter(a => a.tipo !== 'counselor');
const counselors = alunos.filter(a => a.tipo === 'counselor');
const acompDe = new Map();
for (const c of acomp) acompDe.set(c.aluno_id, (acompDe.get(c.aluno_id) || 0) + 1);

const ativos = alunos.filter(a => a.ativo);
const acompAtivos = acomp.filter(c => ativos.some(a => a.id === c.aluno_id));

const pendentesAprovacao = alunos.filter(a => !a.ativo).length;
const emailNaFila = alunos.filter(a => !a.email_confirmacao_em).length;

/* Duplicata: mesmo nome, mais de uma linha. É o erro mais comum —
   família que preenche duas vezes achando que não enviou. */
const porNome = new Map();
for (const a of alunos) {
  const k = (a.nome || '').trim().toLowerCase();
  if (!k) continue;
  if (!porNome.has(k)) porNome.set(k, []);
  porNome.get(k).push(a);
}
const duplicados = [...porNome.values()].filter(v => v.length > 1);

/* Sem canal de contato nenhum: nem e-mail do responsável, nem do
   aluno. Recebe crachá e aparece para o representante, mas não dá
   para salvar. */
const semContato = alunos.filter(a =>
  !(a.responsavel_email || '').trim() && !(a.email || '').trim());

/* Inscrições por dia, para ver o ritmo. */
const porDia = contar(alunos, a => (a.criado_em || '').slice(0, 10)).sort();

const barras = (dados, cor = 'var(--azul)') => {
  if (!dados.length) return '<p class="vazio">Nada ainda.</p>';
  const max = Math.max(...dados.map(d => d[1]));
  return '<table class="barras">' + dados.map(([rot, n]) => `
    <tr>
      <th>${esc(rot)}</th>
      <td class="n">${n}</td>
      <td class="b"><span style="width:${(n / max * 100).toFixed(1)}%;background:${cor}"></span></td>
    </tr>`).join('') + '</table>';
};

const cartao = (valor, rotulo, obs = '', destaque = false) => `
  <div class="cartao${destaque && valor > 0 ? ' alerta' : ''}">
    <strong>${valor}</strong>
    <span>${esc(rotulo)}</span>
    ${obs ? `<em>${esc(obs)}</em>` : ''}
  </div>`;

const agora = new Date().toLocaleString('pt-BR');

const html = `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Painel de inscrições — Career Day</title>
<style>
  :root { --azul:#1478d0; --vermelho:#b02020; --texto:#201e1d; --cinza:#605d5d; --linha:#e3e0e0; }
  * { box-sizing: border-box; }
  body { margin:0; background:#f3f2f2; color:var(--texto);
         font:15px/1.5 -apple-system, "Segoe UI", Roboto, sans-serif; }
  .env { max-width:1080px; margin:0 auto; padding:28px 20px 60px; }

  header { display:flex; flex-wrap:wrap; align-items:baseline; justify-content:space-between;
           gap:12px; border-bottom:2px solid var(--texto); padding-bottom:14px; margin-bottom:8px; }
  h1 { margin:0; font-size:22px; letter-spacing:-.02em; }
  .quando { font-size:13px; color:var(--cinza); }

  .aviso { margin:16px 0 26px; padding:12px 16px; background:#fff4d6; color:#7a5100;
           border-left:5px solid #d69a00; font-size:13.5px; }

  .cartoes { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; margin-bottom:30px; }
  .cartao { background:#fff; border:1px solid var(--linha); padding:16px 18px; }
  .cartao strong { display:block; font-size:30px; line-height:1.1; letter-spacing:-.02em; }
  .cartao span { display:block; font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:var(--cinza); margin-top:4px; }
  .cartao em { display:block; font-style:normal; font-size:12px; color:var(--cinza); margin-top:6px; }
  .cartao.alerta { border-color:var(--vermelho); }
  .cartao.alerta strong { color:var(--vermelho); }

  section { background:#fff; border:1px solid var(--linha); padding:18px 20px; margin-bottom:18px; }
  h2 { margin:0 0 14px; font-size:15px; text-transform:uppercase; letter-spacing:.08em; color:var(--cinza); }
  .duplas { display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:18px; }

  table { width:100%; border-collapse:collapse; font-size:14px; }
  .barras th { text-align:left; font-weight:500; padding:5px 10px 5px 0; white-space:nowrap; }
  .barras td.n { width:44px; text-align:right; padding-right:10px; font-variant-numeric:tabular-nums; color:var(--cinza); }
  .barras td.b { width:100%; }
  .barras td.b span { display:block; height:9px; }

  .lista th { text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:.07em;
              color:var(--cinza); border-bottom:1px solid var(--linha); padding:7px 8px 7px 0; }
  .lista td { padding:7px 8px 7px 0; border-bottom:1px solid #f1efef; vertical-align:top; }
  .tag { display:inline-block; padding:1px 7px; font-size:11px; border:1px solid var(--linha); }
  .tag.counselor { border-color:var(--azul); color:var(--azul); }
  .pend { color:var(--vermelho); }
  .vazio { color:var(--cinza); font-size:13.5px; margin:0; }
</style>
</head>
<body>
<div class="env">

<header>
  <h1>Inscrições · Career Day – Alfa University Fair</h1>
  <span class="quando">Foto de ${agora}</span>
</header>

<p class="aviso"><b>Este arquivo contém nome e e-mail de menores de idade.</b>
Não publique, não suba para a hospedagem e apague quando não precisar mais.
Para atualizar os números, rode <code>node scripts/painel.mjs</code> de novo.</p>

<div class="cartoes">
  ${cartao(alunos.length, 'inscrições', `${estudantes.length} alunos · ${counselors.length} counselors`)}
  ${cartao(acomp.length, 'acompanhantes')}
  ${cartao(alunos.length + acomp.length, 'crachás no total', 'se todos forem aprovados')}
  ${cartao(ativos.length + acompAtivos.length, 'crachás aprovados', 'estes saem na impressão')}
  ${cartao(pendentesAprovacao, 'aguardando aprovação', '', true)}
  ${cartao(emailNaFila, 'e-mails na fila', '', true)}
</div>

<div class="duplas">
  <section>
    <h2>Por unidade / colégio</h2>
    ${barras(contar(estudantes, a => a.tipo === 'counselor' ? null : (a.unidade || a.colegio)))}
  </section>

  <section>
    <h2>Por ano de escolaridade</h2>
    ${barras(contar(estudantes, a => a.ano_escolaridade))}
  </section>

  <section>
    <h2>Países de interesse</h2>
    ${barras(contar(estudantes, a => a.paises_interesse), 'var(--vermelho)')}
  </section>

  <section>
    <h2>Acompanhamento no evento</h2>
    ${barras(contar(estudantes, a => a.responsavel_acompanha))}
  </section>

  <section>
    <h2>Counselors por instituição</h2>
    ${barras(contar(counselors, a => a.colegio), 'var(--azul)')}
  </section>

  <section>
    <h2>Inscrições por dia</h2>
    ${barras(porDia.map(([d, n]) => [d.split('-').reverse().slice(0, 2).join('/'), n]))}
  </section>
</div>

${duplicados.length ? `
<section>
  <h2>⚠ Possíveis duplicatas — mesmo nome mais de uma vez</h2>
  <table class="lista">
    <tr><th>Nome</th><th>Vezes</th><th>Contatos</th></tr>
    ${duplicados.map(g => `<tr>
      <td>${esc(g[0].nome)}</td>
      <td>${g.length}</td>
      <td>${esc(g.map(x => x.responsavel_email || x.email || '—').join(' · '))}</td>
    </tr>`).join('')}
  </table>
</section>` : ''}

${semContato.length ? `
<section>
  <h2>⚠ Sem nenhum canal de contato</h2>
  <p class="vazio">Recebem crachá e aparecem para o representante, mas não há e-mail para salvar.</p>
  <table class="lista">
    <tr><th>Nome</th><th>Tipo</th></tr>
    ${semContato.map(a => `<tr><td>${esc(a.nome)}</td><td>${esc(a.tipo)}</td></tr>`).join('')}
  </table>
</section>` : ''}

<section>
  <h2>Últimas inscrições</h2>
  <table class="lista">
    <tr>
      <th>Quando</th><th>Tipo</th><th>Nome</th><th>Onde estuda</th>
      <th>Contato</th><th>Acomp.</th><th>Aprovado</th><th>E-mail</th>
    </tr>
    ${alunos.slice(0, 40).map(a => `<tr>
      <td>${esc(new Date(a.criado_em).toLocaleDateString('pt-BR'))}</td>
      <td><span class="tag${a.tipo === 'counselor' ? ' counselor' : ''}">${a.tipo === 'counselor' ? 'counselor' : 'aluno'}</span></td>
      <td>${esc(a.nome)}</td>
      <td>${esc(a.tipo === 'counselor' ? a.colegio : (a.unidade || a.colegio || '—'))}</td>
      <td>${esc(a.responsavel_email || a.email || '—')}</td>
      <td>${acompDe.get(a.id) || 0}</td>
      <td>${a.ativo ? 'sim' : '<span class="pend">pendente</span>'}</td>
      <td>${a.email_confirmacao_em ? 'enviado' : '<span class="pend">na fila</span>'}</td>
    </tr>`).join('')}
  </table>
  ${alunos.length > 40 ? `<p class="vazio">Mostrando as 40 mais recentes de ${alunos.length}.</p>` : ''}
</section>

</div>
</body>
</html>
`;

mkdirSync('saida', { recursive: true });
writeFileSync('saida/painel.html', html, 'utf8');

console.log(`${alunos.length} inscrição(ões) e ${acomp.length} acompanhante(s) em saida/painel.html`);
console.log(`  ${estudantes.length} aluno(s) · ${counselors.length} counselor(s)`);
console.log(`  ${pendentesAprovacao} aguardando aprovação · ${emailNaFila} e-mail(s) na fila`);
if (duplicados.length) console.log(`  ATENÇÃO: ${duplicados.length} nome(s) repetido(s) — confira no painel.`);
console.log('\nAbra saida/painel.html no navegador.');
console.log('Contém dado pessoal de menores: não publique e apague quando não precisar.');
