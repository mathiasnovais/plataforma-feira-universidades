-- ============================================================
-- 0052 — Um link só, para todo mundo
--
-- Mandar 33 links diferentes obriga a montar 33 e-mails com o
-- endereço certo em cada um — e o erro que isso convida (colar o
-- link do Rodrigo no e-mail da Lauana) não dá aviso nenhum. Com
-- um link geral, o mesmo endereço vai no e-mail, no grupo de
-- WhatsApp e no slide, e acabou.
--
-- O QUE SE PERDE, E É CONCRETO
--
-- A lista de quem falta responder. Ela vinha da marca que o link
-- pessoal deixava em `avaliadores.respondeu_pesquisa_em`; sem
-- link pessoal, ninguém é identificado e não há o que marcar.
-- Você saberá QUANTAS respostas chegaram, nunca de quem faltou.
--
-- Também some a trava de uma resposta por convite: com um código
-- só, o servidor não tem como distinguir a segunda resposta de
-- uma pessoa da primeira resposta de outra. Sobra uma trava no
-- navegador, que serve contra toque duplo e recarregar a página,
-- e não contra quem quiser insistir.
--
-- OS DOIS CAMINHOS CONVIVEM
--
-- Os links pessoais da 0049/0050 continuam valendo. Quem usar o
-- pessoal é marcado como respondente (e responde uma vez só);
-- quem usar o geral não é marcado. Não se perde o que já existe,
-- e dá para mandar o geral para todos e o pessoal só para quem
-- você quiser cobrar depois.
--
-- POR QUE UM CÓDIGO, E NÃO A PÁGINA SOLTA
--
-- `registrar_avaliacao` é executável por `anon` — precisa ser,
-- para a página pública funcionar. Sem nenhum código, o endereço
-- vira um formulário aberto na internet, e a primeira varredura
-- automática que passar enche a tabela de lixo. O código de 8
-- posições não protege contra quem foi convidado; protege contra
-- quem nunca foi.
--
-- Para ENCERRAR a pesquisa: update pesquisa_evento set aberta =
-- false. O link passa a dizer que o prazo acabou, em vez de
-- aceitar resposta em janeiro sobre um evento de agosto.
-- ============================================================

-- ------------------------------------------------------------
-- 1. A configuração da pesquisa
--
-- Uma linha só, garantida pelo primary key booleano com CHECK: a
-- coluna só aceita `true`, então não existe segunda linha para
-- alguém editar por engano e ficar se perguntando qual das duas
-- vale.
-- ------------------------------------------------------------
create table if not exists public.pesquisa_evento (
  id        boolean primary key default true check (id),
  codigo    text not null unique,
  aberta    boolean not null default true,
  criado_em timestamptz not null default now()
);

insert into public.pesquisa_evento (id, codigo)
select true, public.gen_codigo_avaliacao()
 where not exists (select 1 from public.pesquisa_evento);

alter table public.pesquisa_evento enable row level security;
revoke all on public.pesquisa_evento from anon, authenticated;

comment on table public.pesquisa_evento is
  'Código do link geral da pesquisa e se ela está aberta. Uma '
  'linha só. Para encerrar: update pesquisa_evento set aberta = false.';

-- ------------------------------------------------------------
-- 2. O convite aceita os dois códigos
--
-- Geral primeiro: é o caminho que vai ser usado por todos, e
-- deixá-lo depois faria toda abertura varrer `avaliadores` à toa.
-- ------------------------------------------------------------
create or replace function public.avaliacao_convite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_codigo text := public.normalizar_codigo(p_token);
  v_cfg    pesquisa_evento%rowtype;
  v_quando timestamptz;
  v_achou  boolean;
begin
  select * into v_cfg from pesquisa_evento limit 1;

  -- (a) link geral
  if v_cfg.codigo is not null and upper(v_cfg.codigo) = v_codigo then
    if not v_cfg.aberta then
      raise exception 'pesquisa_encerrada';
    end if;
    return jsonb_build_object('ok', true, 'geral', true, 'ja_respondeu', false);
  end if;

  -- (b) link pessoal, como na 0051
  select respondeu_pesquisa_em, true
    into v_quando, v_achou
    from avaliadores
   where upper(avaliacao_token) = v_codigo;

  if not coalesce(v_achou, false) then
    raise exception 'convite_invalido';
  end if;

  return jsonb_build_object(
    'ok',           true,
    'geral',        false,
    'ja_respondeu', v_quando is not null);
end;
$$;

-- ------------------------------------------------------------
-- 3. Gravar por qualquer um dos dois
--
-- A gravação da resposta é idêntica nos dois caminhos — é o mesmo
-- formulário e a mesma tabela sem vínculo. O que muda é só o que
-- acontece ANTES: o pessoal confere se já foi usado e marca
-- depois; o geral não confere nem marca.
-- ------------------------------------------------------------
create or replace function public.registrar_avaliacao(p_token text, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_codigo text := public.normalizar_codigo(p_token);
  v_cfg    pesquisa_evento%rowtype;
  v_geral  boolean := false;
  v_id     uuid;
  v_quando timestamptz;
  v_lista  text[];
  n        smallint;
begin
  select * into v_cfg from pesquisa_evento limit 1;

  if v_cfg.codigo is not null and upper(v_cfg.codigo) = v_codigo then
    if not v_cfg.aberta then
      raise exception 'pesquisa_encerrada';
    end if;
    v_geral := true;

  else
    select id, respondeu_pesquisa_em into v_id, v_quando
      from avaliadores
     where upper(avaliacao_token) = v_codigo;

    if v_id is null then
      raise exception 'convite_invalido';
    end if;
    if v_quando is not null then
      raise exception 'ja_respondeu';
    end if;
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

  if not v_geral then
    update avaliadores set respondeu_pesquisa_em = now() where id = v_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.avaliacao_convite(text)          to anon, authenticated;
grant execute on function public.registrar_avaliacao(text, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- QUAL É O LINK GERAL
--
--   select codigo, aberta from public.pesquisa_evento;
--
-- O endereço é https://SEU-DOMINIO/avaliacao#CODIGO — o hífen no
-- meio do código é enfeite e pode entrar ou não; normalizar_codigo
-- descarta.
--
-- Para trocar o código (invalida o link antigo na hora):
--   update public.pesquisa_evento set codigo = public.gen_codigo_avaliacao();
--
-- Para encerrar a pesquisa:
--   update public.pesquisa_evento set aberta = false;
--
-- CONFERÊNCIA DEPOIS DE RODAR
--
--   select public.avaliacao_convite((select codigo from public.pesquisa_evento));
--   -- {"ok": true, "geral": true, "ja_respondeu": false}
--
--   select public.avaliacao_convite((select avaliacao_token from public.avaliadores limit 1));
--   -- {"ok": true, "geral": false, "ja_respondeu": false}
-- ------------------------------------------------------------
