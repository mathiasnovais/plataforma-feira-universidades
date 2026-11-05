/* ============================================================
   Criação em lote dos avaliadores
   Passo 4 da seção 13 dos requisitos.

   Lê um CSV, cria o usuário em auth.users e insere a linha
   correspondente em public.avaliadores. Idempotente: rodar duas
   vezes não duplica nada.

   Sem npm install. Node 18+ já tem fetch embutido.

   USO (PowerShell):
     $env:SUPABASE_SERVICE_ROLE = "cole_a_service_role_aqui"
     node scripts/criar-avaliadores.mjs avaliadores.csv
     node scripts/criar-avaliadores.mjs gestores.csv --gestor

   --gestor grava papel = 'gestor' (0017): quem enxerga o painel
   com os nomes. Sem a opção, todo mundo entra como 'avaliador' —
   escaneia crachá e não vê o painel. São funções separadas, e a
   diferença é essa única palavra, então ela é explícita no
   comando em vez de deduzida do nome do arquivo.

   A service_role fica só nesta variável de ambiente da sessão do
   terminal. Não vai para arquivo nenhum e some quando você fechar
   o PowerShell.

   FORMATO DO CSV (primeira linha é cabeçalho):
     nome,email,organizacao
     Maria Souza,maria@empresa.com,Empresa X
     João Lima,joao@outra.com,Outra Empresa
   ============================================================ */

import { readFileSync } from 'node:fs';
import { exigirChave, exigirUrl } from './chave.mjs';

const URL_PROJETO = exigirUrl();
const CHAVE = exigirChave();
const argumentos = process.argv.slice(2);
const GESTOR = argumentos.includes('--gestor');
const ARQUIVO = argumentos.find(a => !a.startsWith('--'));

if (!ARQUIVO) {
  console.error('Uso: node scripts/criar-avaliadores.mjs arquivo.csv [--gestor]');
  process.exit(1);
}

const cabecalhos = {
  apikey: CHAVE,
  Authorization: 'Bearer ' + CHAVE,
  'Content-Type': 'application/json'
};

/* Parser de CSV mínimo: aceita campo entre aspas com vírgula dentro. */
function lerCsv(texto) {
  const linhas = texto.replace(/\r\n?/g, '\n').split('\n').filter(l => l.trim());
  const colunas = linhas.shift().split(',').map(c => c.trim().toLowerCase());

  return linhas.map(linha => {
    const campos = [];
    let atual = '', dentroDeAspas = false;
    for (const ch of linha) {
      if (ch === '"') dentroDeAspas = !dentroDeAspas;
      else if (ch === ',' && !dentroDeAspas) { campos.push(atual); atual = ''; }
      else atual += ch;
    }
    campos.push(atual);
    return Object.fromEntries(colunas.map((c, i) => [c, (campos[i] || '').trim()]));
  });
}

/* Mapa e-mail -> id dos usuários que já existem, para não recriar. */
async function usuariosExistentes() {
  const mapa = new Map();
  for (let pagina = 1; ; pagina++) {
    const r = await fetch(`${URL_PROJETO}/auth/v1/admin/users?page=${pagina}&per_page=200`,
                          { headers: cabecalhos });
    if (!r.ok) throw new Error('Falha ao listar usuários: ' + await r.text());
    const { users } = await r.json();
    if (!users || !users.length) break;
    for (const u of users) mapa.set(u.email.toLowerCase(), u.id);
    if (users.length < 200) break;
  }
  return mapa;
}

async function criarUsuario(email) {
  const r = await fetch(`${URL_PROJETO}/auth/v1/admin/users`, {
    method: 'POST',
    headers: cabecalhos,
    // email_confirm: true — o avaliador entra por OTP, não precisa
    // clicar em link de confirmação antes.
    body: JSON.stringify({ email, email_confirm: true })
  });
  if (!r.ok) throw new Error(await r.text());
  return (await r.json()).id;
}

async function gravarAvaliadores(linhas) {
  const r = await fetch(`${URL_PROJETO}/rest/v1/avaliadores`, {
    method: 'POST',
    headers: { ...cabecalhos, Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify(linhas)
  });
  if (!r.ok) throw new Error(await r.text());
}

/* ---------------------------------------------------------- */

const registros = lerCsv(readFileSync(ARQUIVO, 'utf8'));
console.log(`${registros.length} linha(s) no CSV.`);

const existentes = await usuariosExistentes();
console.log(`${existentes.size} usuário(s) já em auth.users.`);

const paraGravar = [];
let criados = 0, reaproveitados = 0, falhas = 0;

for (const reg of registros) {
  const email = (reg.email || '').toLowerCase().trim();
  if (!email || !reg.nome) { console.warn('  pulando linha sem nome ou e-mail'); falhas++; continue; }

  try {
    let id = existentes.get(email);
    if (id) reaproveitados++;
    else { id = await criarUsuario(email); criados++; }

    /* O upsert é por `id`, então o papel é reescrito a cada
       execução. Rodar sem --gestor num CSV de gestores rebaixaria
       todo mundo para avaliador sem avisar — daí o aviso no fim. */
    paraGravar.push({
      id, nome: reg.nome, email,
      organizacao: reg.organizacao || null,
      papel: GESTOR ? 'gestor' : 'avaliador'
    });
  } catch (e) {
    console.error(`  ERRO em ${email}: ${e.message}`);
    falhas++;
  }
}

if (paraGravar.length) await gravarAvaliadores(paraGravar);

console.log(`\ncriados: ${criados}  |  já existiam: ${reaproveitados}  |  falhas: ${falhas}`);
console.log(`${paraGravar.length} linha(s) em public.avaliadores, papel = '${GESTOR ? 'gestor' : 'avaliador'}'.`);

if (GESTOR) {
  console.log('\nGestor enxerga o painel com nome, e-mail e telefone de todos os');
  console.log('inscritos — inclusive menores de idade. Confira a lista acima.');
} else if (/gestor/i.test(ARQUIVO)) {
  console.log('\nATENÇÃO: o arquivo se chama "' + ARQUIVO + '" mas você rodou SEM --gestor.');
  console.log('Essas pessoas ficaram como avaliador e não abrem o painel.');
  console.log('Rode de novo com --gestor se a intenção era o contrário.');
}
if (falhas) console.log('\nRevise as falhas acima antes do evento.');
