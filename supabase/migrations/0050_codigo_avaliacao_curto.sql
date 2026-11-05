-- ============================================================
-- 0050 — Link da pesquisa mais curto
--
-- O token da 0049 são 32 caracteres hexadecimais, e o endereço
-- inteiro passa de 90 caracteres:
--
--   .../avaliacao#125e9c15a14844b382083b7a6a1fbbdf
--
-- Num e-mail HTML isso não aparece — o link vive atrás de um
-- texto clicável. Mas o convite também vai ser mandado por
-- WhatsApp, colado em slide e, na pior das hipóteses, ditado por
-- telefone. Aí o tamanho e o alfabeto passam a doer.
--
-- Passa a ser um código de 8 posições no mesmo alfabeto dos
-- crachás (0001): 32 letras e números SEM 0/O/1/I, justamente os
-- quatro que se confundem ao ler em voz alta ou ao digitar de um
-- papel. O link cai para 65 caracteres:
--
--   .../avaliacao#K7M2-QX9R
--
-- CONTINUA NÃO SE ADIVINHANDO
--
-- 32^8 = 1,1 trilhão de combinações para 91 tokens válidos. Uma
-- tentativa às cegas acerta com probabilidade de 8 em 100
-- bilhões. E o que se ganha acertando é responder uma pesquisa de
-- satisfação no lugar de outra instituição — não há dado de aluno
-- atrás deste código.
--
-- OS LINKS ANTIGOS DEIXAM DE VALER
--
-- Esta migration troca o código de todo mundo. Quem já tiver o
-- link velho recebe `convite_invalido`. Como nenhum convite foi
-- enviado ainda, o custo é zero — mas se algum tiver saído, é
-- preciso mandar o novo.
-- ============================================================

-- ------------------------------------------------------------
-- 1. O gerador
--
-- Igual ao gen_codigo_curto() da 0001, com 8 posições em vez de
-- 6. Não reaproveitei aquele porque 6 posições foram escolhidas
-- para o crachá, que é conferido por uma pessoa na mesa; aqui o
-- código é a única credencial, e o dobro de espaço custa dois
-- caracteres.
-- ------------------------------------------------------------
create or replace function public.gen_codigo_avaliacao()
returns text
language sql
volatile
as $$
  select string_agg(
    substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
           (floor(random() * 32) + 1)::int, 1), '')
  from generate_series(1, 8);
$$;

revoke execute on function public.gen_codigo_avaliacao() from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. Trocar o código de todo mundo
--
-- Linha a linha, com repetição até achar um livre. Com 91 linhas
-- num espaço de 1,1 trilhão, o laço não roda duas vezes na
-- prática — mas gerar em massa e torcer para o UNIQUE não
-- reclamar é o tipo de aposta que falha no dia errado.
-- ------------------------------------------------------------
do $troca$
declare
  r     record;
  novo  text;
  n     integer := 0;
begin
  for r in select id from public.avaliadores loop
    loop
      novo := public.gen_codigo_avaliacao();
      exit when not exists (
        select 1 from public.avaliadores where avaliacao_token = novo);
    end loop;

    update public.avaliadores set avaliacao_token = novo where id = r.id;
    n := n + 1;
  end loop;

  raise notice '% codigo(s) de pesquisa trocado(s).', n;
end
$troca$;

alter table public.avaliadores
  alter column avaliacao_token set default public.gen_codigo_avaliacao();

comment on column public.avaliadores.avaliacao_token is
  'Código do link da pesquisa. 8 posições, alfabeto sem 0/O/1/I. '
  'Guardado sem hífen; a leitura ignora hífen, espaço e caixa.';

-- ------------------------------------------------------------
-- 3. A leitura passa a perdoar formatação
--
-- O link é escrito com hífen no meio — `K7M2-QX9R` — porque
-- oito caracteres corridos são difíceis de ler e de ditar. O
-- hífen é enfeite: não está guardado, e some antes da consulta.
--
-- Some junto qualquer espaço que venha de copiar e colar torto, e
-- a caixa é normalizada. Quem digitar `k7m2 qx9r` entra igual.
-- ------------------------------------------------------------
create or replace function public.normalizar_codigo(p_texto text)
returns text
language sql
immutable
as $$
  select nullif(upper(regexp_replace(coalesce(p_texto, ''), '[^0-9A-Za-z]', '', 'g')), '');
$$;

revoke execute on function public.normalizar_codigo(text) from public, anon, authenticated;

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
   where upper(avaliacao_token) = public.normalizar_codigo(p_token);

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

-- Mesmo corpo da 0049, com a busca do token normalizada.
create or replace function public.registrar_avaliacao(p_token text, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id     uuid;
  v_lista  text[];
  n        smallint;
begin
  select id into v_id from avaliadores
   where upper(avaliacao_token) = public.normalizar_codigo(p_token);

  if v_id is null then
    raise exception 'convite_invalido';
  end if;

  n := nullif(p_dados->>'q1_geral', '')::smallint;
  if n is null then
    raise exception 'resposta_vazia';
  end if;

  select coalesce(array_agg(valor), '{}')
    into v_lista
    from jsonb_array_elements_text(coalesce(p_dados->'q10_interesses', '[]'::jsonb)) as valor;

  insert into avaliacoes_evento (
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
    v_lista
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

-- create or replace preserva grants, mas repetir não custa.
grant execute on function public.avaliacao_convite(text)          to anon, authenticated;
grant execute on function public.registrar_avaliacao(text, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- CONFERÊNCIA DEPOIS DE RODAR
--
--   -- 8 posições, todos distintos, nenhum com caractere confuso
--   select count(*)                                as total,
--          count(distinct avaliacao_token)         as distintos,
--          min(length(avaliacao_token))            as menor,
--          max(length(avaliacao_token))            as maior,
--          count(*) filter (where avaliacao_token ~ '[01OI]') as confusos
--     from public.avaliadores;
--   -- distintos = total, menor = maior = 8, confusos = 0
--
--   -- o convite abre com hífen, sem hífen e em minúscula
--   select public.avaliacao_convite(
--            (select avaliacao_token from public.avaliadores limit 1)) -> 'nome';
-- ------------------------------------------------------------
