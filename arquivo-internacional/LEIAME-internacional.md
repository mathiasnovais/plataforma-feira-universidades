# Instalação

Referência completa: `requisitos-plataforma-avaliadores.md`.

## 1. Banco

No SQL Editor do Supabase, rode **na ordem**:

1. `supabase/migrations/0001_schema.sql`
2. `supabase/migrations/0002_rls.sql`
3. `supabase/migrations/0003_funcoes_acesso.sql`
4. `supabase/migrations/0004_grants.sql`

Migrations já aplicadas não se edita — problema vira `0004_*.sql`.

Confira depois de rodar:

```sql
-- alunos e log_acesso: rowsecurity = true, zero policies
select tablename, rowsecurity from pg_tables where schemaname = 'public';
select tablename, policyname from pg_policies where schemaname = 'public';

-- anon não pode chamar nada
select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon_executa
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public';
```

`anon_executa` tem que ser `false` em tudo.

## 2. Auth

- Authentication → Providers → Email: **Enable signup = OFF**

- Entrega do código: **Send Email Hook apontando para o n8n**
  (`n8n/enviar-otp.json`). O SMTP embutido do Supabase só entrega para
  endereços de membros da organização no Supabase — nenhum avaliador é
  membro, então ninguém receberia o código. Com o hook ativo o Supabase
  não manda e-mail nenhum e a restrição deixa de existir.

  Passos:
  1. n8n: importar `n8n/enviar-otp.json`, configurar a credencial SMTP
     no nó *Enviar e-mail*, ajustar `DOMINIOS_PERMITIDOS` no nó
     *Validar payload*, ativar o workflow e copiar a URL de produção
     do webhook.
  2. Supabase → Authentication → Hooks → **Send Email Hook** → tipo
     HTTP → colar a URL. Gere o secret que ele oferece e guarde.
  3. Testar o login. O Supabase continua gerando e validando o código;
     o n8n só entrega.

  Alternativa se o n8n sair do ar: desligar o hook no painel e cair de
  volta no SMTP do Supabase. Vale ter um SMTP próprio (Resend/Brevo)
  configurado como rede de segurança, mesmo usando o hook.

- Authentication → Rate Limits → **"Rate limit for sending emails"**:
  o padrão é baixo (na ordem de 30/hora) e **continua valendo mesmo
  com SMTP próprio**. Com 100 avaliadores logando na abertura, os
  primeiros 30 entram e o resto recebe `over_email_send_rate_limit`.
  Subir para pelo menos 200/hora.

- Verificação de domínio leva tempo (DNS). Fazer **semanas antes**,
  não na véspera.

- Testar o pico de login **antes** do evento.

## 3. Dados

- Alunos: importar CSV pelo Table Editor. `cracha_token` e `codigo_curto`
  são gerados sozinhos. `consentimento_responsavel` precisa vir `true`
  para quem consentiu — **sem isso o nível cai para 0 e o app não
  mostra nem salva nada**, mesmo com `nivel_compartilhamento = 3`.
- Avaliadores: em lote, pelo script. Quem existe no auth mas não em
  `avaliadores` recebe `sem_permissao` ao escanear — o script cuida
  dos dois lados.

  ```powershell
  $env:SUPABASE_SERVICE_ROLE = "cole_a_service_role_aqui"
  node scripts/criar-avaliadores.mjs avaliadores.csv
  ```

  CSV com cabeçalho `nome,email,organizacao`. Rodar duas vezes não
  duplica. A chave fica só na variável de sessão do terminal.

## 4. Front

As telas leem a URL e a chave anon de um `config.js` na raiz. Copie
`config.exemplo.js` para `config.js` e preencha:

```js
window.CONFIG = {
  SUPABASE_URL: 'https://SEU-PROJETO.supabase.co',
  SUPABASE_ANON_KEY: 'SUA_CHAVE_ANON'
};
```

Publicar no Cloudflare Pages. Sem build.

**Publique apenas estes quatro arquivos:**

```
index.html
config.js
sw.js
manifest.webmanifest
```

Não suba a pasta do projeto inteira. `supabase/`, `scripts/`, `n8n/` e
principalmente `saida/` não podem ir para a hospedagem — `saida/` contém
nome e token de todos os alunos.

O QR do crachá aponta para `https://SEU-DOMINIO/#/p/<cracha_token>`,
usando o valor da coluna `alunos.cracha_token`. Nada além do token.

### Ao publicar uma correção durante o evento

O `sw.js` guarda o app em cache. Trocar `const CACHE = 'contatos-v1'`
para `'contatos-v2'` força a atualização em todos os dispositivos.

## 5. Crachás

```powershell
node scripts/gerar-crachas.mjs https://SEU-DOMINIO --exemplo   # confere o layout
$env:SUPABASE_SERVICE_ROLE = "cole_a_service_role_aqui"
node scripts/gerar-crachas.mjs --situacao                      # fila e levas já impressas
node scripts/gerar-crachas.mjs https://SEU-DOMINIO             # a próxima leva
```

Gera um arquivo por categoria — `saida/crachas-leva-00N-alunos.html`,
`-responsaveis.html`, `-counselors.html`, `-docentes.html` — porque é assim
que os crachás são separados na mesa. Abra cada um no navegador e imprima com
Ctrl+P → Salvar como PDF, com **escala em 100%** e **gráficos de fundo
ligados**. Reduzir a escala encolhe o QR e piora a leitura no papel.

**Imprime por leva.** Cada geração leva só quem ainda não imprimiu e carimba
essa gente (`alunos.cracha_lote`, migration 0027). Aprovar um grupo novo e
gerar de novo não traz os antigos de volta — sem isso sairiam dois papéis com
o mesmo QR circulando no evento. Reimpressão de uma leva: `--lote N`. Desfazer
uma leva que não foi impressa: `--desmarcar N`. Detalhes em `docs/crachas.md`.

A URL passada no comando entra dentro do QR. Precisa ser a **definitiva** —
trocar de domínio depois obriga a reimprimir os 600 crachás. Publique no
Cloudflare Pages e confirme o endereço antes de imprimir.

Os arquivos em `saida/` têm nome e token de todos os alunos. Não publique,
não suba para a hospedagem, apague depois de imprimir — `--lote N` regenera.

Crachás de avaliadores, responsáveis e equipe são gerados fora do sistema,
a partir de planilha — só o crachá do aluno carrega QR funcional.

## 6. Teste de campo

Passo 8 da seção 13 dos requisitos. Não pule. Com crachás impressos de
verdade, sob a luz do local, e pelo menos um celular em modo avião do
começo ao fim.

## 7. Depois do evento — mandar os leads

```powershell
node scripts/leads-avaliadores.mjs
```

Gera em `saida/leads/` uma planilha `.xlsx` e um HTML por avaliador, com os
contatos que **aquela pessoa** salvou, mais a nota e o comentário que ela
escreveu. O `indice.html` traz a lista de envio (nome, e-mail, quantos
leads, qual arquivo anexar) e um modelo de e-mail para copiar.

**O arquivo tem o nome do e-mail de quem recebe** — `fulano@universidade.edu.xlsx`.
É o mesmo texto que vai no campo "Para", então achar o anexo certo é
procurar pelo endereço. Nome de pessoa não serve aqui: dois homônimos
geram o mesmo arquivo, e anexar a lista de um para o outro não dá erro
nenhum — dá um vazamento silencioso de dado de menor para a universidade
errada.

A planilha sai pronta: aba com o nome do avaliador, cabeçalho congelado e
com filtro, largura de coluna ajustada, nota como número e "salvo em" como
data de verdade — ordenar por data sai cronológico, não alfabético. Quem
gera é `scripts/xlsx.mjs`, escrito no projeto para não precisar de
`npm install`: um .xlsx é um zip de XML, e o Node já traz o zip.

**As colunas são exatamente as que o app mostrava ao avaliador.** O script
refaz em JavaScript as regras de `nivel_efetivo` e `responsavel_liberado`,
porque a `service_role` não passa por `perfil_aluno()` e leria a tabela
crua. Se alguma dessas regras mudar no banco, mude no script junto —
está comentado lá.

Quem revogou o consentimento depois do evento sai da exportação inteira,
não com as colunas em branco. O contato continua no banco; só não é mais
distribuído. A contagem aparece no fim e no índice.

### Pesquisa de feedback das universidades

O formulário do `CAREER DAY.pdf` virou tela: `avaliacao.html`, bilíngue,
dez questões. Migration `0049_avaliacao_evento.sql`.

1. Rode a migration. Ela cria `avaliacoes_evento` e dá a cada avaliador um
   `avaliacao_token`.
2. Publique `avaliacao.html` (o `preparar-deploy.mjs` já a copia).
3. Gere o índice com o endereço do site para os links saírem prontos:

   ```powershell
   node scripts/leads-avaliadores.mjs --site https://SEU-DOMINIO
   ```

   Cada linha do índice passa a ter o link da pesquisa daquela pessoa, para
   colar no mesmo e-mail que leva a planilha de leads.
4. Para ler o resultado: `node scripts/avaliacoes.mjs` → `saida/avaliacoes.xlsx`,
   com resumo (média, nº de respostas, menor e maior), respostas linha a linha
   e quem ainda não respondeu.

**A pesquisa é anônima de verdade** (migration `0051`). A resposta não guarda
quem respondeu nem quando — só a marca `avaliadores.respondeu_pesquisa_em`,
noutra tabela, diz quem já respondeu, para você cobrar quem falta. O texto do
PDF, que promete anonimato nas duas línguas, está na tela e é verdadeiro.

Duas consequências: **não dá para cruzar nota com volume de leads** por
universidade, e **cada convite responde uma vez só** — sem vínculo, nem o
servidor sabe qual linha é de quem, então não há o que reabrir para corrigir.

A tela é dividida em 6 passos com barra de progresso; só a pergunta 1 é
obrigatória. O código do link tem 8 posições no alfabeto dos crachás
(`K7M2-QX9R`), e hífen, espaço e caixa são ignorados na leitura.

### Pesquisa de feedback das famílias

O `Alfacem_Global_Academy_Feedback_Pais.pdf` virou tela:
`avaliacao-familias.html`, seis questões, **só em português** — quem responde é
família da rede, e inglês ao lado seria enfeite roubando espaço no celular.
Migration `0053_pesquisa_familias.sql`.

1. Rode a migration. Ela cria `avaliacoes_familias` e `pesquisa_familias`, esta
   última já com o código do link sorteado.
2. Publique (o `preparar-deploy.mjs` já copia a página e as duas artes).
3. Pegue o link:

   ```sql
   select codigo, aberta from public.pesquisa_familias;
   ```

   O endereço é `https://SEU-DOMINIO/avaliacao-familias#CODIGO`. **É um só para
   todas as famílias** — vai no e-mail, no grupo, no QR impresso.
4. Para ler o resultado: `node scripts/avaliacoes-familias.mjs` →
   `saida/avaliacoes-familias.xlsx`, com resumo (média geral e média separada
   por responsável / aluno / juntos), respostas linha a linha e uma aba só com
   os comentários abertos.

Para encerrar: `update public.pesquisa_familias set aberta = false;`

**Diferenças em relação à pesquisa das universidades**, e cada uma tem motivo:

| | Universidades | Famílias |
|---|---|---|
| Idioma | inglês e português | só português |
| Link | um por pessoa (e um geral) | um só, para todas |
| Etapas | 6 | 3 |
| Carimbo de tempo | não guarda | guarda |

O carimbo é o ponto sutil. A `0051` teve de tirar até a data da resposta das
universidades porque lá existe uma marca de "fulano já respondeu" em
`avaliadores`, e duas listas com horário permitem parear uma com a outra. Aqui
não há marca nenhuma nem segunda lista, então a data não abre caminho de volta
para ninguém — e mostra o ritmo das respostas ao longo dos dias.

A pergunta "quem está respondendo" (responsável / aluno / os dois) **não está
no PDF** — acrescentei porque a mesma pergunta produz respostas diferentes na
boca de quem levou o filho e na de quem foi levado, e separar as médias é a
primeira coisa que se quer olhar. É opcional e não identifica ninguém. Se
preferir a pesquisa idêntica ao papel, é só remover.

### Pacote do patrocinador master

```powershell
node scripts/leads-avaliadores.mjs --patrocinador "Nome do patrocinador"
```

Acrescenta um `patrocinador-<nome>.xlsx` com **todos os alunos que estiveram
na feira** — os credenciados na entrada mais os que algum avaliador leu o
crachá no salão (13 pessoas entraram sem passar pela mesa nesta edição, e só
o credenciamento as perderia). Counselors e docentes ficam de fora: outra
base de inscrição, e o pedido é a lista de alunos.

**Sem nota e sem comentário.** Aquilo é anotação de trabalho de um
representante de universidade sobre um aluno que ele visitou; não pertence
a mais ninguém.

**A flag existe para a decisão ser consciente.** O termo que o responsável
assinou fala em compartilhamento com *avaliadores* para contato posterior
(migration 0010, e o item "finalidade declarada" da seção 10 dos
requisitos). Patrocinador que não escaneou ninguém é outro destinatário, e a
lista é maior do que a soma do que os avaliadores visitaram. Confirme o
texto do termo antes de enviar — o script não decide isso por você, só
recusa mandar quem não autoriza compartilhamento nenhum.

`saida/leads/` tem nome, e-mail e telefone de menores separados por
destinatário. Não publique, não suba para o Drive, apague depois do envio
— rodar de novo regenera.

## Página de inscrição internacional

A página de inscrição da edição internacional era um pacote HTML gerado por ferramenta externa e não está neste repositório. O script `scripts/ligar-formulario.mjs` documenta como ela era ligada ao banco (URL e chave vêm de `config.js`).
