-- ============================================================
-- 0049 — Pesquisa de feedback das universidades
--
-- O formulário em papel (CAREER DAY.pdf) vira tela. Dez questões,
-- bilíngues, respondidas pelos representantes que estiveram no
-- salão — é o público das perguntas 4, 5 e 6, que falam da
-- interação com os alunos, do inglês deles e do app de captura.
--
-- COMO A PESSOA É IDENTIFICADA SEM LOGIN
--
-- A feira acabou. Exigir que o representante entre no app de novo
-- para responder derruba a taxa de resposta a quase zero, e o
-- convite vai por e-mail junto com a planilha de leads dele.
--
-- Então cada avaliador ganha um token opaco, e o link do e-mail
-- carrega esse token. Mesmo padrão do `cracha_token` do aluno
-- (0001): quem tem o token responde por aquela conta, sem senha.
-- 32 caracteres hex não se adivinha.
--
-- O preço é o de sempre com link secreto: quem encaminhar o
-- e-mail entrega a própria vez de responder. Para uma pesquisa de
-- satisfação com 38 destinatários conhecidos, é troca aceitável —
-- não há nada a ganhar respondendo no lugar de outro.
--
-- ATENÇÃO — A RESPOSTA NÃO É ANÔNIMA
--
-- O PDF que circulou diz, em negrito, "completely anonymous /
-- totalmente anônima". Esta tabela guarda `avaliador_id`: dá para
-- saber quem respondeu o quê. Foi decisão consciente, para poder
-- cruzar a nota com o volume de leads de cada universidade.
--
-- Quem for enviar precisa corrigir o texto do PDF e o do e-mail
-- ANTES. Prometer anonimato e guardar identidade é o tipo de
-- coisa que destrói a confiança de um parceiro institucional de
-- uma vez só — e, sob a LGPD, é tratamento sem informação
-- adequada ao titular. A tela de avaliacao.html já nasce dizendo
-- a verdade: "sua resposta é identificada pela instituição".
-- ============================================================

-- ------------------------------------------------------------
-- 1. O token do convite
-- ------------------------------------------------------------
alter table public.avaliadores
  add column if not exists avaliacao_token text;

-- Preenche quem já existe. O default cobre quem entrar depois.
update public.avaliadores
   set avaliacao_token = public.gen_cracha_token()
 where avaliacao_token is null;

alter table public.avaliadores
  alter column avaliacao_token set default public.gen_cracha_token();

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'avaliadores_avaliacao_token_key') then
    alter table public.avaliadores
      add constraint avaliadores_avaliacao_token_key unique (avaliacao_token);
  end if;
end
$$;

comment on column public.avaliadores.avaliacao_token is
  'Chave do link da pesquisa de satisfação. Opaca, sem senha. '
  'Quem tem o token responde por esta conta.';

-- ------------------------------------------------------------
-- 2. As respostas
--
-- Coluna por pergunta, não um jsonb só. A pesquisa existe para
-- virar média e comparação — `avg(q3_sinalizacao)` numa coluna de
-- verdade é uma linha de SQL, e o mesmo dentro de jsonb é uma
-- expressão que ninguém escreve na pressa. O formulário é fechado
-- e não muda entre respostas; jsonb resolveria um problema que
-- aqui não existe.
--
-- Nota nula = "N/A" marcado, ou pergunta não respondida. Os dois
-- casos querem a mesma coisa no cálculo: ficar de fora da média,
-- que é o que avg() faz sozinho com nulo. Zerar seria pior — 0
-- entra na conta e derruba a média de quem não opinou.
-- ------------------------------------------------------------
create table if not exists public.avaliacoes_evento (
  id            uuid primary key default gen_random_uuid(),
  avaliador_id  uuid not null unique
                references public.avaliadores(id) on delete cascade,

  -- 1 e 2: escalas simples de 1 a 5
  q1_geral        smallint check (q1_geral        between 1 and 5),
  q2_pre_evento   smallint check (q2_pre_evento   between 1 and 5),

  -- 3: organização e infraestrutura
  q3_chegada        smallint check (q3_chegada        between 1 and 5),
  q3_estande_espaco smallint check (q3_estande_espaco between 1 and 5),
  q3_estande_local  smallint check (q3_estande_local  between 1 and 5),
  q3_sinalizacao    smallint check (q3_sinalizacao    between 1 and 5),
  q3_fluxo          smallint check (q3_fluxo          between 1 and 5),
  q3_infra_tecnica  smallint check (q3_infra_tecnica  between 1 and 5),
  q3_suporte        smallint check (q3_suporte        between 1 and 5),
  q3_organizacao    smallint check (q3_organizacao    between 1 and 5),

  -- 4: qualidade da interação com os alunos
  q4_interesse      smallint check (q4_interesse      between 1 and 5),
  q4_perguntas      smallint check (q4_perguntas      between 1 and 5),
  q4_confianca      smallint check (q4_confianca      between 1 and 5),
  q4_consciencia    smallint check (q4_consciencia    between 1 and 5),
  q4_geral          smallint check (q4_geral          between 1 and 5),

  -- 5: inglês dos alunos (N/A vira nulo)
  q5_ingles         smallint check (q5_ingles         between 1 and 5),

  -- 6: a plataforma de captura de leads
  q6_acesso         smallint check (q6_acesso         between 1 and 5),
  q6_uso            smallint check (q6_uso            between 1 and 5),
  q6_captura        smallint check (q6_captura        between 1 and 5),
  q6_confiabilidade smallint check (q6_confiabilidade between 1 and 5),
  q6_utilidade      smallint check (q6_utilidade      between 1 and 5),

  -- 7: valor da participação
  q7_valor          smallint check (q7_valor          between 1 and 5),

  -- 8: probabilidade de voltar. Vai de ZERO a 10, não de 1 a 10 —
  -- é escala de recomendação (NPS), e o zero é resposta válida e
  -- a mais informativa de todas.
  q8_voltaria       smallint check (q8_voltaria       between 0 and 10),

  -- 9: as duas metades da pergunta aberta, em campos separados.
  -- No papel vêm juntas e a resposta sai grudada; separadas, dá
  -- para ler todas as melhorias em sequência.
  q9_ponto_forte    text,
  q9_melhoria       text,

  -- 10: interesses de colaboração, múltipla escolha
  q10_interesses    text[] not null default '{}',

  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- Uma resposta por instituição, editável: o `unique` em
-- avaliador_id mais o upsert da função. Quem clicar duas vezes no
-- link corrige a resposta em vez de criar uma segunda linha, e a
-- média não conta ninguém duas vezes.
create trigger avaliacoes_evento_atualizado_em
  before update on public.avaliacoes_evento
  for each row execute function public.tocar_atualizado_em();

alter table public.avaliacoes_evento enable row level security;

-- Sem policy nenhuma, como `alunos` e `log_acesso` (0002): todo
-- acesso passa pelas funções SECURITY DEFINER abaixo.
revoke all on public.avaliacoes_evento from anon, authenticated;

-- ------------------------------------------------------------
-- 3. Abrir o convite
--
-- Devolve o nome e a organização de quem o token identifica, para
-- a tela poder dizer "Olá, Lauana — IE" e mostrar a resposta
-- anterior se já houver uma. Não devolve e-mail: a tela não
-- precisa, e link encaminhado não deve virar consulta de contato.
-- ------------------------------------------------------------
create or replace function public.avaliacao_convite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_av avaliadores%rowtype;
  v_r  avaliacoes_evento%rowtype;
begin
  select * into v_av from avaliadores
   where avaliacao_token = lower(trim(p_token));

  if not found then
    raise exception 'convite_invalido';
  end if;

  select * into v_r from avaliacoes_evento where avaliador_id = v_av.id;

  return jsonb_build_object(
    'ok',           true,
    'nome',         v_av.nome,
    'organizacao',  v_av.organizacao,
    'ja_respondeu', found,
    'respostas',    case when found then to_jsonb(v_r) - 'id' - 'avaliador_id' end
  );
end;
$$;

-- ------------------------------------------------------------
-- 4. Gravar a resposta
--
-- Cada campo é lido do jsonb com cast explícito e nulo quando
-- ausente. Fora da faixa, o CHECK da tabela recusa — a validação
-- da tela pode ser burlada, esta não.
-- ------------------------------------------------------------
create or replace function public.registrar_avaliacao(p_token text, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id     uuid;
  v_paises text[];
  n        smallint;
begin
  select id into v_id from avaliadores
   where avaliacao_token = lower(trim(p_token));

  if v_id is null then
    raise exception 'convite_invalido';
  end if;

  -- Pelo menos a primeira pergunta: formulário em branco enviado
  -- por engano não vira linha e não entra na média.
  n := nullif(p_dados->>'q1_geral', '')::smallint;
  if n is null then
    raise exception 'resposta_vazia';
  end if;

  select coalesce(array_agg(valor), '{}')
    into v_paises
    from jsonb_array_elements_text(coalesce(p_dados->'q10_interesses', '[]'::jsonb)) as valor;

  insert into avaliacoes_evento as a (
    avaliador_id,
    q1_geral, q2_pre_evento,
    q3_chegada, q3_estande_espaco, q3_estande_local, q3_sinalizacao,
    q3_fluxo, q3_infra_tecnica, q3_suporte, q3_organizacao,
    q4_interesse, q4_perguntas, q4_confianca, q4_consciencia, q4_geral,
    q5_ingles,
    q6_acesso, q6_uso, q6_captura, q6_confiabilidade, q6_utilidade,
    q7_valor, q8_voltaria,
    q9_ponto_forte, q9_melhoria, q10_interesses
  ) values (
    v_id,
    nullif(p_dados->>'q1_geral', '')::smallint,
    nullif(p_dados->>'q2_pre_evento', '')::smallint,
    nullif(p_dados->>'q3_chegada', '')::smallint,
    nullif(p_dados->>'q3_estande_espaco', '')::smallint,
    nullif(p_dados->>'q3_estande_local', '')::smallint,
    nullif(p_dados->>'q3_sinalizacao', '')::smallint,
    nullif(p_dados->>'q3_fluxo', '')::smallint,
    nullif(p_dados->>'q3_infra_tecnica', '')::smallint,
    nullif(p_dados->>'q3_suporte', '')::smallint,
    nullif(p_dados->>'q3_organizacao', '')::smallint,
    nullif(p_dados->>'q4_interesse', '')::smallint,
    nullif(p_dados->>'q4_perguntas', '')::smallint,
    nullif(p_dados->>'q4_confianca', '')::smallint,
    nullif(p_dados->>'q4_consciencia', '')::smallint,
    nullif(p_dados->>'q4_geral', '')::smallint,
    nullif(p_dados->>'q5_ingles', '')::smallint,
    nullif(p_dados->>'q6_acesso', '')::smallint,
    nullif(p_dados->>'q6_uso', '')::smallint,
    nullif(p_dados->>'q6_captura', '')::smallint,
    nullif(p_dados->>'q6_confiabilidade', '')::smallint,
    nullif(p_dados->>'q6_utilidade', '')::smallint,
    nullif(p_dados->>'q7_valor', '')::smallint,
    nullif(p_dados->>'q8_voltaria', '')::smallint,
    nullif(trim(p_dados->>'q9_ponto_forte'), ''),
    nullif(trim(p_dados->>'q9_melhoria'), ''),
    v_paises
  )
  on conflict (avaliador_id) do update set
    q1_geral = excluded.q1_geral,
    q2_pre_evento = excluded.q2_pre_evento,
    q3_chegada = excluded.q3_chegada,
    q3_estande_espaco = excluded.q3_estande_espaco,
    q3_estande_local = excluded.q3_estande_local,
    q3_sinalizacao = excluded.q3_sinalizacao,
    q3_fluxo = excluded.q3_fluxo,
    q3_infra_tecnica = excluded.q3_infra_tecnica,
    q3_suporte = excluded.q3_suporte,
    q3_organizacao = excluded.q3_organizacao,
    q4_interesse = excluded.q4_interesse,
    q4_perguntas = excluded.q4_perguntas,
    q4_confianca = excluded.q4_confianca,
    q4_consciencia = excluded.q4_consciencia,
    q4_geral = excluded.q4_geral,
    q5_ingles = excluded.q5_ingles,
    q6_acesso = excluded.q6_acesso,
    q6_uso = excluded.q6_uso,
    q6_captura = excluded.q6_captura,
    q6_confiabilidade = excluded.q6_confiabilidade,
    q6_utilidade = excluded.q6_utilidade,
    q7_valor = excluded.q7_valor,
    q8_voltaria = excluded.q8_voltaria,
    q9_ponto_forte = excluded.q9_ponto_forte,
    q9_melhoria = excluded.q9_melhoria,
    q10_interesses = excluded.q10_interesses;

  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 5. Permissões
--
-- As duas funções ficam abertas para `anon`: a página da pesquisa
-- é pública e usa a chave anon do navegador. O que protege é o
-- token — sem ele, as duas levantam `convite_invalido` e não
-- devolvem nada. Nenhuma delas lê dado de aluno.
-- ------------------------------------------------------------
revoke execute on function public.avaliacao_convite(text)          from public;
revoke execute on function public.registrar_avaliacao(text, jsonb) from public;

grant execute on function public.avaliacao_convite(text)          to anon, authenticated;
grant execute on function public.registrar_avaliacao(text, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- CONFERÊNCIA DEPOIS DE RODAR
--
--   -- todo avaliador tem token, e nenhum repetido
--   select count(*) as total,
--          count(avaliacao_token) as com_token,
--          count(distinct avaliacao_token) as distintos
--     from public.avaliadores;
--
--   -- o convite abre (troque pelo token de alguém)
--   select public.avaliacao_convite(
--            (select avaliacao_token from public.avaliadores limit 1));
--
-- Depois, com respostas na mesa, as médias saem assim:
--
--   select round(avg(q1_geral), 2)   as geral,
--          round(avg(q7_valor), 2)   as valor,
--          round(avg(q8_voltaria), 2) as voltaria,
--          count(*)                  as respostas
--     from public.avaliacoes_evento;
-- ------------------------------------------------------------
