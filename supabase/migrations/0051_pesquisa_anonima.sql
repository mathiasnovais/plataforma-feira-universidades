-- ============================================================
-- 0051 — A pesquisa passa a ser anônima de verdade
--
-- O convite que vai às universidades diz, no cabeçalho e em duas
-- línguas: "This survey is completely anonymous / Esta pesquisa é
-- totalmente anônima". A 0049 guardava `avaliador_id` na linha da
-- resposta — dava para saber quem respondeu o quê. As duas coisas
-- não podem coexistir: ou a frase sai, ou o vínculo sai.
--
-- Sai o vínculo.
--
-- O QUE SE PERDE
--
-- Não dá mais para cruzar a nota com o volume de leads de cada
-- universidade, que era a razão de ter sido identificada. Também
-- não dá para reabrir o link e corrigir a resposta: sem vínculo,
-- ninguém — nem o servidor — sabe qual linha é de quem.
--
-- O QUE SE MANTÉM
--
-- Saber QUEM já respondeu, para cobrar quem falta. Isso vira uma
-- marca em `avaliadores.respondeu_pesquisa_em`, numa tabela
-- diferente da resposta e sem nada que aponte para a linha. É a
-- separação padrão de urna: a lista de quem votou é pública, o
-- voto não.
--
-- ATÉ ONDE VAI O ANONIMATO — sendo honesto
--
-- Contra quem recebe a planilha de resultados, é total: não há
-- coluna que ligue resposta a instituição.
--
-- Contra quem tem acesso SQL ao banco, é forte mas não absoluto.
-- Duas frestas, e as duas foram fechadas até onde dá:
--
--   1. Carimbo de tempo. Se a resposta guardasse a hora e a marca
--      do avaliador também, bastaria parear as duas listas. Por
--      isso a resposta NÃO guarda mais data nenhuma. Quem quiser
--      saber quando a pesquisa andou olha as marcas, que são de
--      pessoas, não de respostas.
--
--   2. Ordem física das linhas. Um `select` sem `order by`
--      costuma devolver na ordem de inserção, que é a mesma ordem
--      em que as marcas foram carimbadas. Contra isso não há
--      defesa barata dentro do Postgres — fica registrado aqui
--      para quem for responder pela pesquisa saber que existe.
--      Explorar exige acesso de administrador ao banco, que é de
--      quem organizou o evento.
--
-- Nenhuma resposta havia sido gravada quando esta migration foi
-- escrita, então não há histórico a converter.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Corta o vínculo
--
-- O drop leva junto o UNIQUE e a foreign key da coluna.
-- ------------------------------------------------------------
alter table public.avaliacoes_evento
  drop column if exists avaliador_id;

-- A data de criação era o outro caminho de volta. Some junto.
alter table public.avaliacoes_evento
  drop column if exists criado_em,
  drop column if exists atualizado_em;

drop trigger if exists avaliacoes_evento_atualizado_em on public.avaliacoes_evento;

comment on table public.avaliacoes_evento is
  'Respostas da pesquisa de satisfação das universidades. SEM '
  'vínculo com quem respondeu e SEM carimbo de tempo, de '
  'propósito: o convite promete anonimato. Quem já respondeu '
  'está em avaliadores.respondeu_pesquisa_em, que não aponta '
  'para linha nenhuma daqui.';

-- ------------------------------------------------------------
-- 2. A marca de quem já respondeu
-- ------------------------------------------------------------
alter table public.avaliadores
  add column if not exists respondeu_pesquisa_em timestamptz;

comment on column public.avaliadores.respondeu_pesquisa_em is
  'Quando esta pessoa respondeu a pesquisa. Serve para cobrar '
  'quem falta. NÃO identifica qual resposta é dela.';

-- ------------------------------------------------------------
-- 3. O convite não devolve mais nome nem resposta anterior
--
-- Nome saiu por pedido: o cabeçalho da pesquisa é institucional e
-- não precisa saudar ninguém. Resposta anterior saiu por
-- necessidade: sem vínculo, não há como saber qual é.
--
-- Sobra dizer se o convite vale e se já foi usado — o suficiente
-- para a tela decidir entre mostrar o formulário e agradecer.
-- ------------------------------------------------------------
create or replace function public.avaliacao_convite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_quando timestamptz;
  v_achou  boolean;
begin
  select respondeu_pesquisa_em, true
    into v_quando, v_achou
    from avaliadores
   where upper(avaliacao_token) = public.normalizar_codigo(p_token);

  if not coalesce(v_achou, false) then
    raise exception 'convite_invalido';
  end if;

  return jsonb_build_object(
    'ok',           true,
    'ja_respondeu', v_quando is not null);
end;
$$;

-- ------------------------------------------------------------
-- 4. Gravar: uma vez por convite, sem deixar rastro de quem
--
-- Some o upsert da 0049: `on conflict (avaliador_id)` não existe
-- mais porque a coluna não existe mais. No lugar, a marca vira a
-- trava — quem já respondeu recebe `ja_respondeu` e a tela
-- agradece em vez de abrir o formulário de novo.
--
-- Marca e resposta na mesma transação: ou entram as duas, ou
-- nenhuma. Sem isso, uma falha no meio deixaria a pessoa marcada
-- como respondente sem resposta gravada — e sem como refazer.
-- ------------------------------------------------------------
create or replace function public.registrar_avaliacao(p_token text, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id     uuid;
  v_quando timestamptz;
  v_lista  text[];
  n        smallint;
begin
  select id, respondeu_pesquisa_em into v_id, v_quando
    from avaliadores
   where upper(avaliacao_token) = public.normalizar_codigo(p_token);

  if v_id is null then
    raise exception 'convite_invalido';
  end if;

  if v_quando is not null then
    raise exception 'ja_respondeu';
  end if;

  n := nullif(p_dados->>'q1_geral', '')::smallint;
  if n is null then
    raise exception 'resposta_vazia';
  end if;

  select coalesce(array_agg(valor), '{}')
    into v_lista
    from jsonb_array_elements_text(coalesce(p_dados->'q10_interesses', '[]'::jsonb)) as valor;

  insert into avaliacoes_evento (
    q1_geral, q2_pre_evento,
    q3_chegada, q3_estande_espaco, q3_estande_local, q3_sinalizacao,
    q3_fluxo, q3_infra_tecnica, q3_suporte, q3_organizacao,
    q4_interesse, q4_perguntas, q4_confianca, q4_consciencia, q4_geral,
    q5_ingles,
    q6_acesso, q6_uso, q6_captura, q6_confiabilidade, q6_utilidade,
    q7_valor, q8_voltaria,
    q9_ponto_forte, q9_melhoria, q10_interesses
  ) values (
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
  );

  update avaliadores set respondeu_pesquisa_em = now() where id = v_id;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.avaliacao_convite(text)          to anon, authenticated;
grant execute on function public.registrar_avaliacao(text, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- CONFERÊNCIA DEPOIS DE RODAR
--
--   -- não sobrou nenhuma coluna que ligue resposta a pessoa
--   select column_name from information_schema.columns
--    where table_schema = 'public' and table_name = 'avaliacoes_evento'
--      and column_name in ('avaliador_id', 'criado_em', 'atualizado_em');
--   -- tem de vir vazio
--
--   -- o convite abre e diz que ainda não foi usado
--   select public.avaliacao_convite(
--            (select avaliacao_token from public.avaliadores limit 1));
--   -- {"ok": true, "ja_respondeu": false}
--
--   -- quem falta responder, depois que os convites saírem
--   select nome, organizacao from public.avaliadores
--    where papel = 'avaliador' and presente
--      and respondeu_pesquisa_em is null
--    order by organizacao, nome;
-- ------------------------------------------------------------
