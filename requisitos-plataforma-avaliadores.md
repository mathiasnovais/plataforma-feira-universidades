# Plataforma de Captura de Contatos por QR Code — Levantamento de Requisitos

**Versão:** 1.0
**Escala:** ~600 participantes, evento presencial de dia único
**Princípio norteador:** menor número possível de partes móveis

---

## 1. Decisões travadas

| # | Decisão | Impacto |
|---|---|---|
| 1 | Alunos são menores; consentimento do responsável coletado na inscrição | Nenhum fluxo de consentimento dentro do app |
| 2 | Apenas avaliadores escaneiam | Só avaliadores autenticam; aluno não faz login |
| 3 | Nível de compartilhamento definido na inscrição e imutável durante o evento | Perfil pode ser cacheado no dispositivo sem invalidação |
| 4 | Aluno não escaneia ninguém | Sem papel "aluno" no auth |
| 5 | Contatos ficam no banco, enviados depois do evento | Sem integração de CRM em tempo real |
| 6 | Planos pagos liberados, prioridade é simplicidade | Supabase Pro; sem otimização prematura |

**Consequência de (2) e (4):** o responsável com crachá não precisa existir no banco. O crachá dele é identificação visual apenas — gerado a partir de planilha, fora do sistema.

---

## 2. Arquitetura

```
┌─────────────────────────────────────────┐
│  index.html  (arquivo único, estático)  │
│  supabase-js via CDN + html5-qrcode      │
│  Cloudflare Pages / Netlify — grátis     │
└──────────────────┬──────────────────────┘
                   │ HTTPS + JWT
                   ▼
┌─────────────────────────────────────────┐
│  SUPABASE (Pro)                          │
│  • Auth — OTP por e-mail, signup OFF     │
│  • Postgres + RLS                        │
│  • RPC buscar_aluno() SECURITY DEFINER   │
└──────────────────┬──────────────────────┘
                   │ service_role (assíncrono)
                   ▼
┌─────────────────────────────────────────┐
│  n8n — só automação fora do caminho      │
│  crítico: crachás, e-mails pós-evento    │
└─────────────────────────────────────────┘
```

### Por que o n8n não serve o HTML

Cada carregamento de página viraria uma execução de workflow: latência maior, contagem no limite de execuções, concorrência limitada e — o problema sério — dados pessoais de menores gravados no log de execução do n8n. Página estática em CDN não tem nenhum desses problemas e custa zero.

### Por que HTML único em vez de React/Next

Não há necessidade de build, CI, node_modules ou deploy pipeline. O app tem 4 telas. Um arquivo de ~600 linhas resolve, é auditável de ponta a ponta e você consegue corrigir um bug no meio do evento pelo celular.

---

## 3. Escopo

### Dentro

- Login de avaliador por código OTP enviado ao e-mail
- Restrição a e-mails pré-cadastrados
- Scanner de QR contínuo pela câmera
- Entrada manual por código curto (fallback)
- Exibição do perfil do aluno conforme nível de compartilhamento
- Salvar contato com nota e comentário
- Lista "Meus contatos" com busca
- Fila offline com sincronização automática
- Log de acessos (accountability LGPD)
- Geração em lote dos crachás com QR
- Envio pós-evento da lista de contatos para cada avaliador

### Fora (não construir)

- Login de aluno ou de responsável
- Alteração de nível de compartilhamento durante o evento
- Chat, notificações push, feed
- Integração com CRM em tempo real
- App nativo em loja
- Painel administrativo web — o Table Editor do Supabase resolve

---

## 4. Requisitos funcionais

### RF-01 — Autenticação
O avaliador informa o e-mail e recebe um **código de 6 dígitos**. Não usar magic link: no celular o link frequentemente abre em navegador diferente daquele onde a sessão foi iniciada e o login se perde. Sessão persistida em `localStorage`; o avaliador loga uma vez e permanece logado durante todo o evento.

### RF-02 — Controle de acesso
Signups desabilitados no painel do Supabase. Usuários criados previamente via Admin API a partir da lista de avaliadores. O cliente chama `signInWithOtp` com `shouldCreateUser: false` — e-mail fora da lista recebe erro e não gera usuário.

### RF-03 — Leitura do QR
Scanner contínuo com `html5-qrcode` (usa zxing-wasm internamente). Não depender da API nativa `BarcodeDetector`: suporte inconsistente no Safari iOS. Câmera traseira por padrão (`facingMode: environment`). Feedback tátil (`navigator.vibrate`) e sonoro na leitura bem-sucedida.

### RF-04 — Entrada manual
Campo para digitar o código curto impresso no crachá. Cobre crachá amassado, com reflexo, virado ou câmera negada. **Este requisito não é opcional** — é o que impede a fila travar.

### RF-05 — Exibição do perfil
Chamada única ao RPC `buscar_aluno(codigo)`. O servidor decide quais campos retornar. O front nunca recebe campo que o aluno não autorizou — filtro no cliente é inaceitável.

### RF-06 — Salvar contato
Botão único. Upsert em `contatos_salvos` com PK composta `(avaliador_id, aluno_id)` — escanear duas vezes atualiza, não duplica. Nota de 1 a 5 e comentário livre, ambos opcionais. Se o aluno estiver em nível 0, o botão fica desabilitado.

### RF-07 — Meus contatos
Lista dos alunos salvos, ordem cronológica inversa, com busca por nome. Renderizada a partir do cache local, revalidada em background.

### RF-08 — Modo offline
Salvamento sem rede vai para fila em `localStorage`. Sincroniza no evento `online` e a cada 30s. Indicador visual de itens pendentes. **Wi-Fi de centro de eventos com 600 pessoas é o maior risco técnico do projeto** — muito acima de qualquer limite do Supabase.

### RF-09 — Geração de crachás
n8n lê a lista de participantes, gera QR + código curto, monta PDF para impressão. Alunos, avaliadores, responsáveis e equipe no mesmo lote — só o crachá do aluno carrega QR funcional.

### RF-10 — Envio pós-evento
Workflow n8n agendado: para cada avaliador, consolida seus contatos em CSV e envia por e-mail. Disparo manual pela organização quando decidir.

---

## 5. Requisitos não funcionais

| Código | Requisito | Alvo |
|---|---|---|
| RNF-01 | Tempo do scan à exibição do perfil | < 1,5 s em 4G |
| RNF-02 | Sessões simultâneas | 100 avaliadores (folga sobre o real) |
| RNF-03 | Disponibilidade durante o evento | Degradação para modo offline, nunca tela branca |
| RNF-04 | Dados pessoais no QR | Zero |
| RNF-05 | Compatibilidade | Safari iOS 15+, Chrome Android 100+ |
| RNF-06 | Retenção dos dados | Definir prazo e agendar expurgo |

**RNF-04 é inegociável.** QR code é legível por qualquer câmera — inclusive em fotos do evento publicadas em redes sociais depois. O QR contém apenas um token opaco:

```
https://app.evento.com/#/p/7f3a9c2e8b1d4056
```

O token é aleatório, sem significado, revogável. Todo dado sai do banco, sob autenticação.

---

## 6. Modelo de dados

Quatro tabelas. Cole o bloco abaixo no SQL Editor do Supabase.

```sql
-- ============================================================
-- 1. UTILITÁRIO: código curto legível (sem 0/O/1/I)
-- ============================================================
create or replace function public.gen_codigo_curto()
returns text language sql volatile as $$
  select string_agg(
    substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
           (floor(random() * 32) + 1)::int, 1), '')
  from generate_series(1, 6);
$$;

-- ============================================================
-- 2. AVALIADORES  (espelha auth.users)
-- ============================================================
create table public.avaliadores (
  id           uuid primary key references auth.users(id) on delete cascade,
  nome         text not null,
  email        text not null unique,
  organizacao  text,
  criado_em    timestamptz not null default now()
);

-- ============================================================
-- 3. ALUNOS  (nunca autenticam — só existem como registro)
-- ============================================================
create table public.alunos (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  turma         text,
  projeto       text,
  resumo        text,           -- pitch de 1-2 linhas
  email         text,
  telefone      text,
  linkedin      text,

  -- 0 = não autoriza | 1 = acadêmico | 2 = +e-mail | 3 = tudo
  nivel_compartilhamento smallint not null default 0
    check (nivel_compartilhamento between 0 and 3),

  -- consentimento do responsável, coletado na inscrição
  consentimento_responsavel boolean not null default false,
  consentimento_versao      text,
  consentimento_em          timestamptz,

  cracha_token  text not null unique default encode(gen_random_bytes(12), 'hex'),
  codigo_curto  text not null unique default public.gen_codigo_curto(),
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

-- ============================================================
-- 4. CONTATOS SALVOS  (PK composta = upsert natural)
-- ============================================================
create table public.contatos_salvos (
  avaliador_id  uuid not null default auth.uid()
                references public.avaliadores(id) on delete cascade,
  aluno_id      uuid not null
                references public.alunos(id) on delete cascade,
  nota          smallint check (nota between 1 and 5),
  comentario    text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  primary key (avaliador_id, aluno_id)
);

create index on public.contatos_salvos (avaliador_id, criado_em desc);

-- ============================================================
-- 5. LOG DE ACESSO  (accountability LGPD)
-- ============================================================
create table public.log_acesso (
  id           bigserial primary key,
  avaliador_id uuid references public.avaliadores(id),
  aluno_id     uuid references public.alunos(id),
  em           timestamptz not null default now()
);
```

### Sobre os níveis

Se o formulário de inscrição oferecer apenas "autorizo / não autorizo", use somente os níveis **0 e 3**. Os níveis 1 e 2 existem para o caso de o formulário ter granularidade maior. A estrutura suporta os dois cenários sem alteração de schema.

---

## 7. Segurança — RLS e função de leitura

### 7.1 Ativação

```sql
alter table public.avaliadores     enable row level security;
alter table public.alunos          enable row level security;
alter table public.contatos_salvos enable row level security;
alter table public.log_acesso      enable row level security;
```

`alunos` e `log_acesso` ficam **sem nenhuma policy**. Com RLS ativo e zero policies, ninguém lê direto — nem o próprio avaliador logado. O acesso passa obrigatoriamente pela função da seção 7.3.

### 7.2 Policies

```sql
-- Avaliador lê apenas o próprio cadastro
create policy "avaliador_le_proprio" on public.avaliadores
  for select to authenticated
  using (id = auth.uid());

-- Avaliador gerencia apenas os próprios contatos
create policy "contatos_select" on public.contatos_salvos
  for select to authenticated using (avaliador_id = auth.uid());

create policy "contatos_insert" on public.contatos_salvos
  for insert to authenticated with check (avaliador_id = auth.uid());

create policy "contatos_update" on public.contatos_salvos
  for update to authenticated
  using (avaliador_id = auth.uid())
  with check (avaliador_id = auth.uid());

create policy "contatos_delete" on public.contatos_salvos
  for delete to authenticated using (avaliador_id = auth.uid());
```

### 7.3 A função que resolve o problema central

RLS filtra **linhas**, não **colunas**. Como o nível de compartilhamento determina quais *campos* aparecem, RLS sozinha não resolve. Uma função `SECURITY DEFINER` resolve os dois problemas — filtro de coluna e registro de log — numa única transação:

```sql
create or replace function public.buscar_aluno(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v alunos%rowtype;
  n smallint;
begin
  -- 1. exige sessão válida de avaliador cadastrado
  if auth.uid() is null then
    raise exception 'nao_autenticado';
  end if;
  if not exists (select 1 from avaliadores where id = auth.uid()) then
    raise exception 'sem_permissao';
  end if;

  -- 2. aceita token do QR ou código curto digitado
  select * into v from alunos
   where ativo
     and (cracha_token = p_codigo or codigo_curto = upper(trim(p_codigo)));

  if not found then
    raise exception 'cracha_nao_encontrado';
  end if;

  -- 3. registra o acesso na mesma transação
  insert into log_acesso (avaliador_id, aluno_id) values (auth.uid(), v.id);

  n := v.nivel_compartilhamento;

  -- 4. devolve SOMENTE os campos autorizados
  return jsonb_build_object(
    'aluno_id',  v.id,
    'nome',      v.nome,
    'nivel',     n,
    'turma',     case when n >= 1 then v.turma    end,
    'projeto',   case when n >= 1 then v.projeto  end,
    'resumo',    case when n >= 1 then v.resumo   end,
    'email',     case when n >= 2 then v.email    end,
    'telefone',  case when n >= 3 then v.telefone end,
    'linkedin',  case when n >= 3 then v.linkedin end,
    'ja_salvo',  exists (select 1 from contatos_salvos c
                          where c.avaliador_id = auth.uid()
                            and c.aluno_id = v.id)
  );
end;
$$;

revoke execute on function public.buscar_aluno(text) from public, anon;
grant  execute on function public.buscar_aluno(text) to authenticated;
```

**Verificação de segurança:** os campos não autorizados nunca saem do Postgres. Mesmo alguém abrindo o DevTools e inspecionando a resposta HTTP não vê o telefone de um aluno de nível 1 — a coluna vem `null` do servidor.

### 7.4 Chamada no cliente

```javascript
const { data, error } = await supabase.rpc('buscar_aluno', { p_codigo: codigo });

// salvar — avaliador_id vem do default auth.uid(), não é enviado
await supabase.from('contatos_salvos').upsert({
  aluno_id: data.aluno_id,
  nota: 4,
  comentario: 'Projeto de robótica, ótimo domínio técnico'
});
```

### 7.5 Força bruta no código curto

32⁶ ≈ 1,07 bilhão de combinações para 600 códigos válidos: 1 chance em 1,8 milhão por tentativa. Risco residual baixo. Se quiser fechar de vez, adicione contador de tentativas por avaliador na `log_acesso` e bloqueie acima de 20 falhas em 5 minutos.

---

## 8. Telas

| # | Tela | Conteúdo |
|---|---|---|
| 1 | Login | Campo e-mail → campo código de 6 dígitos |
| 2 | Scanner | Câmera em tela cheia, link "digitar código", contador de contatos salvos |
| 3 | Perfil do aluno | Dados conforme nível, nota, comentário, botão Salvar |
| 4 | Meus contatos | Lista com busca, badge de pendentes de sincronização |

Regras de interface:

- Área do botão Salvar com no mínimo 48 px de altura — o avaliador usa uma mão só, em pé, segurando material
- Estado "já salvo" visível antes do clique, para evitar re-scan desnecessário
- Nível 0 exibe o nome e o aviso "Este aluno optou por não compartilhar dados de contato", com Salvar desabilitado
- Após salvar, retorno automático ao scanner em 2 segundos

---

## 9. Papel do n8n

Nenhum workflow no caminho crítico. Tudo assíncrono, acessando o Supabase com `service_role`.

| Workflow | Disparo | O que faz |
|---|---|---|
| Criar avaliadores | Manual, pré-evento | Planilha → Admin API cria usuários → insere em `avaliadores` |
| Gerar crachás | Manual, pré-evento | Consulta participantes → gera QR → monta PDF de impressão |
| Envio pós-evento | Manual, pós-evento | Agrupa contatos por avaliador → CSV → e-mail |
| Relatório da organização | Cron diário | Total de scans, contatos por avaliador, alunos sem nenhum scan |

O último tem valor operacional real: durante o evento, mostra qual aluno ainda não recebeu visita de avaliador nenhum.

---

## 10. LGPD

O consentimento já está coletado na inscrição, o que resolve o requisito mais pesado. Confirme que o registro guarda **quem consentiu, quando e sobre qual versão do texto** — os campos `consentimento_*` da tabela `alunos` existem para isso. Consentimento sem versionamento do texto tem valor probatório fraco.

Pontos que ainda precisam de decisão:

- **Prazo de retenção.** Definir por quanto tempo os contatos ficam no banco e agendar o expurgo. Sem prazo definido, o dado fica indefinidamente — o que a LGPD não permite.
- **Finalidade declarada.** O texto do consentimento precisa cobrir explicitamente "compartilhamento com avaliadores para fins de contato posterior". Se disser apenas "participação no evento", o uso está fora da finalidade.
- **Direito de revogação.** Canal para o responsável pedir exclusão. Um e-mail da organização basta; o `delete` cascateia sozinho.
- **`log_acesso` também é dado pessoal.** Entra no mesmo prazo de retenção.

Recomendação: alinhe esses quatro pontos com quem redigiu o termo de consentimento **antes** de começar a desenvolver. É o item que mais atrasa projetos desse tipo quando deixado para o fim.

---

## 11. Custos aproximados

| Item | Custo mensal |
|---|---|
| Supabase Pro | ~US$ 25 |
| Cloudflare Pages | US$ 0 |
| SMTP (Resend/Brevo) | US$ 0 no tier inicial |
| n8n | US$ 0 self-hosted, ~US$ 25 na nuvem |

Ordem de US$ 25–50 no mês do evento. **Confirme os valores atuais** — preços de SaaS mudam e minha referência pode estar defasada.

O SMTP nativo do Supabase é fortemente limitado e não serve para produção. Configure SMTP próprio e **teste o pico de login antes do evento** — 100 avaliadores pedindo OTP nos primeiros 10 minutos é um cenário real.

---

## 12. Riscos

| Risco | Prob. | Impacto | Mitigação |
|---|---|---|---|
| Wi-Fi do local sobrecarregado | **Alta** | Alto | Modo offline (RF-08) — item mais importante do projeto |
| QR ilegível (amassado, reflexo, virado) | Alta | Médio | Código curto (RF-04) |
| Pico de OTP no início | Média | Alto | SMTP próprio + liberar primeiro acesso na véspera |
| Avaliador sem prática com o app | Média | Médio | Card impresso com 3 passos entregue junto ao crachá |
| Bateria do celular do avaliador | Média | Médio | Powerbanks no balcão da organização |
| Aluno com crachá perdido | Baixa | Baixo | Reemissão: gerar novo token e reimprimir |

Note que **nenhum dos riscos principais é de capacidade do banco**. 600 pessoas é volume trivial para o Postgres; os riscos reais são todos operacionais e de conectividade física.

---

## 13. Ordem de execução

1. Rodar o SQL das seções 6 e 7 no Supabase
2. Desabilitar signups; configurar SMTP próprio
3. Importar alunos via CSV pelo Table Editor
4. Criar os usuários avaliadores (workflow n8n ou script)
5. Construir o `index.html` — login → scanner → perfil → lista
6. Adicionar a fila offline
7. Workflow de geração de crachás; imprimir
8. **Teste de campo:** 5 pessoas, 20 crachás reais impressos, incluindo teste com o celular em modo avião
9. Publicar no Cloudflare Pages
10. Liberar primeiro acesso dos avaliadores na véspera
11. Evento
12. Workflow de envio pós-evento
13. Expurgo na data de retenção definida

O passo 8 é o único que não pode ser pulado. Ler QR impresso em papel-crachá sob luz de ginásio é bem diferente de ler QR na tela do monitor.
