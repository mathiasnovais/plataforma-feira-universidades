-- ============================================================
-- 0053 — Pesquisa de feedback das famílias
--
-- Segunda pesquisa do evento, e um público diferente do primeiro:
-- alunos e responsáveis, não universidades. Seis questões, vindas
-- do Alfacem_Global_Academy_Feedback_Pais.pdf.
--
-- POR QUE TABELA NOVA, E NÃO UMA COLUNA "PÚBLICO" NA EXISTENTE
--
-- As perguntas não são as mesmas nem em número nem em sentido:
-- "qualidade e diversidade das universidades participantes" não
-- tem correspondente do outro lado, e "utilidade da plataforma de
-- captação de leads" não faz sentido para uma família. Espremer as
-- duas na mesma tabela renderia uma linha cheia de nulos e uma
-- média que ninguém sabe de quem é.
--
-- As duas também abrem e fecham em datas diferentes, daí a
-- configuração própria.
--
-- SÓ EM PORTUGUÊS
--
-- A pesquisa das universidades é bilíngue porque quem responde é
-- representante estrangeiro. Aqui quem responde é família da rede,
-- no Rio de Janeiro. Inglês ao lado seria enfeite que só rouba
-- espaço na tela do celular.
--
-- ANONIMATO, E POR QUE AQUI CABE UM CARIMBO DE TEMPO
--
-- A 0051 teve de tirar até a data da resposta das universidades:
-- lá existe uma marca de "fulano já respondeu" em `avaliadores`, e
-- duas listas com horário permitiriam parear uma com a outra.
--
-- Aqui não existe marca nenhuma. O convite é um código único para
-- todas as famílias, ninguém é identificado em lugar algum, e não
-- há segunda lista com que cruzar. O `criado_em` então não abre
-- caminho de volta para pessoa alguma — e permite ver o ritmo das
-- respostas ao longo dos dias, que é informação útil e barata.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Configuração: o código do link e se está aberta
--
-- Uma linha só, garantida pelo primary key booleano com CHECK,
-- mesmo padrão da 0052.
-- ------------------------------------------------------------
create table if not exists public.pesquisa_familias (
  id        boolean primary key default true check (id),
  codigo    text not null unique,
  aberta    boolean not null default true,
  criado_em timestamptz not null default now()
);

insert into public.pesquisa_familias (id, codigo)
select true, public.gen_codigo_avaliacao()
 where not exists (select 1 from public.pesquisa_familias);

alter table public.pesquisa_familias enable row level security;
revoke all on public.pesquisa_familias from anon, authenticated;

comment on table public.pesquisa_familias is
  'Código do link e estado da pesquisa das famílias. Uma linha só. '
  'Para encerrar: update pesquisa_familias set aberta = false.';

-- ------------------------------------------------------------
-- 2. As respostas
--
-- Coluna por pergunta, como na 0049: a pesquisa existe para virar
-- média, e média sai de coluna, não de jsonb.
--
-- Nota nula = não respondeu. Fica de fora da média, que é o que
-- avg() faz sozinho com nulo. Zerar seria pior: 0 entra na conta e
-- derruba o resultado de quem não opinou.
-- ------------------------------------------------------------
create table if not exists public.avaliacoes_familias (
  id  uuid primary key default gen_random_uuid(),

  -- Quem respondeu por si: responsável, aluno, ou os dois juntos
  -- na mesma tela. Não identifica ninguém — separa dois olhares
  -- que a mesma pergunta produz de formas diferentes.
  perfil text check (perfil in ('responsavel', 'aluno', 'ambos')),

  q1_geral          smallint check (q1_geral          between 1 and 5),
  q2_organizacao    smallint check (q2_organizacao    between 1 and 5),
  q3_universidades  smallint check (q3_universidades  between 1 and 5),
  q4_contribuicao   smallint check (q4_contribuicao   between 1 and 5),
  q5_valor          smallint check (q5_valor          between 1 and 5),

  -- As duas metades da pergunta 6 em campos separados. No papel
  -- vêm juntas e a resposta sai grudada; separadas, dá para ler
  -- todas as melhorias em sequência.
  q6_ponto_forte    text,
  q6_melhoria       text,

  criado_em timestamptz not null default now()
);

alter table public.avaliacoes_familias enable row level security;
revoke all on public.avaliacoes_familias from anon, authenticated;

comment on table public.avaliacoes_familias is
  'Respostas das famílias. Sem vínculo com quem respondeu: o link é '
  'um código único para todas, e não há marca de participação em '
  'lugar nenhum.';

-- ------------------------------------------------------------
-- 3. Abrir o convite
--
-- Devolve apenas se o código vale e se a pesquisa está no ar — o
-- suficiente para a tela decidir entre mostrar o formulário e
-- avisar que o prazo acabou.
-- ------------------------------------------------------------
create or replace function public.avaliacao_familia_convite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cfg pesquisa_familias%rowtype;
begin
  select * into v_cfg from pesquisa_familias limit 1;

  if v_cfg.codigo is null
     or upper(v_cfg.codigo) is distinct from public.normalizar_codigo(p_token) then
    raise exception 'convite_invalido';
  end if;

  if not v_cfg.aberta then
    raise exception 'pesquisa_encerrada';
  end if;

  return jsonb_build_object('ok', true, 'geral', true, 'ja_respondeu', false);
end;
$$;

-- ------------------------------------------------------------
-- 4. Gravar a resposta
--
-- Sem trava de uma-vez-só: com um código único para todas as
-- famílias, o servidor não tem como distinguir a segunda resposta
-- de uma pessoa da primeira resposta de outra. A trava fica no
-- navegador, e serve contra recarregar a página e toque duplo.
--
-- Fora da faixa, o CHECK da tabela recusa: a validação da tela
-- pode ser burlada, esta não.
-- ------------------------------------------------------------
create or replace function public.registrar_avaliacao_familia(p_token text, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cfg    pesquisa_familias%rowtype;
  v_perfil text;
  n        smallint;
begin
  select * into v_cfg from pesquisa_familias limit 1;

  if v_cfg.codigo is null
     or upper(v_cfg.codigo) is distinct from public.normalizar_codigo(p_token) then
    raise exception 'convite_invalido';
  end if;

  if not v_cfg.aberta then
    raise exception 'pesquisa_encerrada';
  end if;

  -- Pelo menos a primeira pergunta: formulário em branco enviado
  -- por engano não vira linha e não entra na média.
  n := nullif(p_dados->>'q1_geral', '')::smallint;
  if n is null then
    raise exception 'resposta_vazia';
  end if;

  -- Perfil desconhecido vira nulo em vez de derrubar o envio: a
  -- pessoa já respondeu tudo, e perder isso por causa de um campo
  -- opcional seria o pior desfecho possível.
  v_perfil := nullif(trim(p_dados->>'perfil'), '');
  if v_perfil is not null and v_perfil not in ('responsavel', 'aluno', 'ambos') then
    v_perfil := null;
  end if;

  insert into avaliacoes_familias (
    perfil,
    q1_geral, q2_organizacao, q3_universidades, q4_contribuicao, q5_valor,
    q6_ponto_forte, q6_melhoria
  ) values (
    v_perfil,
    nullif(p_dados->>'q1_geral', '')::smallint,
    nullif(p_dados->>'q2_organizacao', '')::smallint,
    nullif(p_dados->>'q3_universidades', '')::smallint,
    nullif(p_dados->>'q4_contribuicao', '')::smallint,
    nullif(p_dados->>'q5_valor', '')::smallint,
    nullif(trim(p_dados->>'q6_ponto_forte'), ''),
    nullif(trim(p_dados->>'q6_melhoria'), '')
  );

  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 5. Permissões
--
-- Abertas para `anon`: a página é pública e usa a chave anon do
-- navegador. O que protege é o código do link — sem ele, as duas
-- levantam `convite_invalido` e não devolvem nada. Nenhuma delas
-- lê dado de aluno.
-- ------------------------------------------------------------
revoke execute on function public.avaliacao_familia_convite(text)          from public;
revoke execute on function public.registrar_avaliacao_familia(text, jsonb) from public;

grant execute on function public.avaliacao_familia_convite(text)          to anon, authenticated;
grant execute on function public.registrar_avaliacao_familia(text, jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- QUAL É O LINK
--
--   select codigo, aberta from public.pesquisa_familias;
--
-- O endereço é https://SEU-DOMINIO/avaliacao-familias#CODIGO — o
-- hífen no meio do código é enfeite e pode entrar ou não;
-- normalizar_codigo (0050) descarta hífen, espaço e caixa.
--
-- Para trocar o código (invalida o link antigo na hora):
--   update public.pesquisa_familias set codigo = public.gen_codigo_avaliacao();
--
-- Para encerrar:
--   update public.pesquisa_familias set aberta = false;
--
-- CONFERÊNCIA DEPOIS DE RODAR
--
--   select public.avaliacao_familia_convite(
--            (select codigo from public.pesquisa_familias));
--   -- {"ok": true, "geral": true, "ja_respondeu": false}
--
-- E, com respostas na mesa:
--
--   select perfil, count(*), round(avg(q1_geral), 2) as geral,
--          round(avg(q5_valor), 2) as valor
--     from public.avaliacoes_familias
--    group by perfil;
-- ------------------------------------------------------------
