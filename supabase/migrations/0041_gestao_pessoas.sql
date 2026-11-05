-- ============================================================
-- 0041 — Gestão de pessoas, para a diretoria
--
-- Uma tela só, dentro do painel do evento, para criar, corrigir e
-- excluir qualquer pessoa do sistema — sem SQL Editor e sem
-- terminal.
--
-- O QUE ESTA MIGRATION NÃO CONSEGUE FAZER, E POR QUÊ
--
-- Criar LOGIN novo. A conta de acesso vive em `auth.users`, e
-- criá-la exige a service_role pela Admin API. Essa chave ignora
-- toda a RLS e não pode existir numa página aberta no navegador —
-- é a regra que o preparar-deploy.mjs verifica a cada publicação.
--
-- Então a divisão é:
--
--   pessoas do evento   (aluno, externo, counselor, docente,
--                        responsável)  -> tudo pela tela
--   contas de acesso    (avaliador, gestor, diretoria)
--                       -> papel e revogação pela tela;
--                          criar continua no criar-avaliadores.mjs
--
-- Revogar acesso apaga a linha de `avaliadores`, não o usuário do
-- auth. A pessoa continua conseguindo digitar o e-mail e receber
-- código, mas nenhuma tela abre para ela: todas exigem a linha em
-- `avaliadores`. É reversível e não perde os contatos que ela
-- salvou.
--
-- TUDO EXIGE DIRETORIA
--
-- Não é `exigir_gestor`. Aqui se apaga aluno e se promove conta —
-- gestor de credenciamento não precisa disso, e marketing muito
-- menos.
-- ============================================================

-- ------------------------------------------------------------
-- admin_pessoas(busca): inscritos e responsáveis numa lista só
-- ------------------------------------------------------------
create or replace function public.admin_pessoas(p_busca text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_diretoria();
  v_b  text := nullif(trim(coalesce(p_busca, '')), '');
begin
  return coalesce((
    select jsonb_agg(linha order by linha->>'ordem')
      from (
        select jsonb_build_object(
                 'kind',     'inscrito',
                 'id',       a.id,
                 'tipo',     coalesce(a.tipo, 'aluno'),
                 'externo',  a.aluno_alfacem is false,
                 'nome',     a.nome,
                 'unidade',  a.unidade,
                 'colegio',  a.colegio,
                 'ano',      a.ano_escolaridade,
                 'email',    a.email,
                 'telefone', a.telefone,
                 'resp_nome',     a.responsavel_nome,
                 'resp_email',    a.responsavel_email,
                 'resp_telefone', a.responsavel_telefone,
                 'ativo',    a.ativo,
                 'presente', a.presente,
                 'codigo',   a.codigo_curto,
                 'cracha_lote', a.cracha_lote,
                 'acompanhantes', (select count(*) from acompanhantes c where c.aluno_id = a.id),
                 'ordem',    public.chave_nome(a.nome)
               ) as linha
          from alunos a
         where v_b is null
            or a.nome ilike '%' || v_b || '%'
            or coalesce(a.responsavel_nome, '') ilike '%' || v_b || '%'
            or coalesce(a.responsavel_email, a.email, '') ilike '%' || v_b || '%'
            or a.codigo_curto ilike '%' || v_b || '%'

        union all

        select jsonb_build_object(
                 'kind',     'responsavel',
                 'id',       c.id,
                 'tipo',     'responsavel',
                 'externo',  false,
                 'nome',     c.nome,
                 'parentesco', c.parentesco,
                 'email',    c.email,
                 'telefone', c.telefone,
                 'de_id',    a.id,
                 'de_nome',  a.nome,
                 'presente', c.presente,
                 'ordem',    public.chave_nome(c.nome)
               ) as linha
          from acompanhantes c
          join alunos a on a.id = c.aluno_id
         where v_b is null
            or c.nome ilike '%' || v_b || '%'
            or a.nome ilike '%' || v_b || '%'
      ) q
  ), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------------
-- admin_salvar_inscrito(dados): cria ou corrige
--
-- Sem `id` cria; com `id` atualiza. Um caminho só, porque os
-- campos são os mesmos e dois caminhos divergem com o tempo.
-- ------------------------------------------------------------
create or replace function public.admin_salvar_inscrito(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin  uuid := public.exigir_diretoria();
  v_id     uuid := nullif(p_dados->>'id', '')::uuid;
  v_tipo   text := coalesce(nullif(trim(p_dados->>'tipo'), ''), 'aluno');
  v_nome   text := nullif(trim(p_dados->>'nome'), '');
  v_rede   boolean := coalesce((p_dados->>'da_rede')::boolean, true);
  v_onde   text := nullif(trim(p_dados->>'onde'), '');
begin
  if v_tipo not in ('aluno', 'counselor', 'docente') then
    raise exception 'tipo_invalido';
  end if;
  if v_nome is null or array_length(string_to_array(v_nome, ' '), 1) < 2 then
    raise exception 'nome_incompleto';
  end if;

  if v_id is null then
    insert into alunos (
      tipo, nome, aluno_alfacem,
      unidade, colegio, ano_escolaridade,
      email, telefone,
      responsavel_nome, responsavel_email, responsavel_telefone,
      nivel_compartilhamento,
      consentimento_responsavel, consentimento_versao, consentimento_em,
      ciencia_compartilhamento, origem, ativo,
      -- Fora da fila de e-mail: quem foi cadastrado à mão pela
      -- direção não deve receber "inscrição confirmada".
      email_confirmacao_em
    ) values (
      v_tipo, v_nome, v_rede,
      case when v_rede then v_onde else null end,
      case when v_rede then null else v_onde end,
      nullif(trim(p_dados->>'ano'), ''),
      lower(nullif(trim(p_dados->>'email'), '')),
      nullif(trim(p_dados->>'telefone'), ''),
      nullif(trim(p_dados->>'resp_nome'), ''),
      lower(nullif(trim(p_dados->>'resp_email'), '')),
      nullif(trim(p_dados->>'resp_telefone'), ''),
      3::smallint,
      true, 'direcao-' || public.versao_consentimento(), now(),
      true, 'balcao', coalesce((p_dados->>'ativo')::boolean, true),
      now()
    )
    returning id into v_id;
  else
    update alunos set
      tipo = v_tipo,
      nome = v_nome,
      aluno_alfacem = v_rede,
      unidade = case when v_rede then v_onde else null end,
      colegio = case when v_rede then null else v_onde end,
      ano_escolaridade = nullif(trim(p_dados->>'ano'), ''),
      email = lower(nullif(trim(p_dados->>'email'), '')),
      telefone = nullif(trim(p_dados->>'telefone'), ''),
      responsavel_nome = nullif(trim(p_dados->>'resp_nome'), ''),
      responsavel_email = lower(nullif(trim(p_dados->>'resp_email'), '')),
      responsavel_telefone = nullif(trim(p_dados->>'resp_telefone'), ''),
      ativo = coalesce((p_dados->>'ativo')::boolean, ativo)
    where id = v_id;

    if not found then raise exception 'nao_encontrado'; end if;
  end if;

  return (select jsonb_build_object(
            'ok', true, 'id', id, 'nome', nome,
            'codigo', codigo_curto, 'cracha_lote', cracha_lote)
            from alunos where id = v_id);
end;
$$;

-- ------------------------------------------------------------
-- admin_salvar_responsavel(dados)
-- ------------------------------------------------------------
create or replace function public.admin_salvar_responsavel(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_diretoria();
  v_id    uuid := nullif(p_dados->>'id', '')::uuid;
  v_de    uuid := nullif(p_dados->>'de_id', '')::uuid;
  v_nome  text := nullif(trim(p_dados->>'nome'), '');
begin
  if v_nome is null then raise exception 'nome_obrigatorio'; end if;

  if v_id is null then
    if v_de is null then raise exception 'inscrito_obrigatorio'; end if;
    if not exists (select 1 from alunos where id = v_de) then
      raise exception 'inscrito_invalido';
    end if;

    insert into acompanhantes (aluno_id, nome, parentesco, email, telefone)
    values (v_de, v_nome,
            nullif(trim(p_dados->>'parentesco'), ''),
            lower(nullif(trim(p_dados->>'email'), '')),
            nullif(trim(p_dados->>'telefone'), ''))
    returning id into v_id;
  else
    update acompanhantes set
      nome = v_nome,
      parentesco = nullif(trim(p_dados->>'parentesco'), ''),
      email = lower(nullif(trim(p_dados->>'email'), '')),
      telefone = nullif(trim(p_dados->>'telefone'), '')
    where id = v_id;

    if not found then raise exception 'nao_encontrado'; end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'nome', v_nome);
end;
$$;

-- ------------------------------------------------------------
-- admin_excluir(kind, id)
--
-- Apagar inscrito cascateia para acompanhantes, contatos salvos e
-- log de acesso (0008). A tela avisa o que vai junto ANTES de
-- perguntar — aqui a função só executa.
-- ------------------------------------------------------------
create or replace function public.admin_excluir(p_kind text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_diretoria();
  v_nome  text;
  v_junto integer := 0;
begin
  if p_kind = 'inscrito' then
    select nome into v_nome from alunos where id = p_id;
    if v_nome is null then raise exception 'nao_encontrado'; end if;
    select count(*) into v_junto from acompanhantes where aluno_id = p_id;
    delete from alunos where id = p_id;

  elsif p_kind = 'responsavel' then
    select nome into v_nome from acompanhantes where id = p_id;
    if v_nome is null then raise exception 'nao_encontrado'; end if;
    delete from acompanhantes where id = p_id;

  else
    raise exception 'kind_invalido';
  end if;

  return jsonb_build_object('ok', true, 'nome', v_nome, 'acompanhantes', v_junto);
end;
$$;

-- ------------------------------------------------------------
-- Contas de acesso
-- ------------------------------------------------------------
create or replace function public.admin_contas()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_diretoria();
begin
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'id', a.id, 'nome', a.nome, 'email', a.email,
               'organizacao', a.organizacao, 'papel', a.papel,
               'presente', a.presente,
               'eu', a.id = v_admin,
               'contatos', (select count(*) from contatos_salvos c where c.avaliador_id = a.id))
             order by a.papel, public.chave_nome(a.nome))
      from avaliadores a
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_papel(p_id uuid, p_papel text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_diretoria();
begin
  if p_papel not in ('avaliador', 'gestor', 'diretoria') then
    raise exception 'papel_invalido';
  end if;

  /* Ninguém rebaixa a si mesmo: sair de diretoria por engano
     tranca a pessoa fora desta tela, e só outra diretoria — ou o
     SQL Editor — poderia devolver. */
  if p_id = v_admin and p_papel <> 'diretoria' then
    raise exception 'nao_rebaixa_a_si';
  end if;

  update avaliadores set papel = p_papel where id = p_id;
  if not found then raise exception 'nao_encontrado'; end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_revogar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_diretoria();
  v_nome  text;
  v_n     integer;
begin
  if p_id = v_admin then raise exception 'nao_revoga_a_si'; end if;

  select nome into v_nome from avaliadores where id = p_id;
  if v_nome is null then raise exception 'nao_encontrado'; end if;

  /* Os contatos que ele salvou continuam no banco, ligados ao
     usuário do auth. Devolver o acesso é recriar a linha pelo
     criar-avaliadores.mjs, e tudo reaparece. */
  select count(*) into v_n from contatos_salvos where avaliador_id = p_id;
  delete from avaliadores where id = p_id;

  return jsonb_build_object('ok', true, 'nome', v_nome, 'contatos', v_n);
end;
$$;

revoke execute on function public.admin_pessoas(text)               from public, anon;
revoke execute on function public.admin_salvar_inscrito(jsonb)      from public, anon;
revoke execute on function public.admin_salvar_responsavel(jsonb)   from public, anon;
revoke execute on function public.admin_excluir(text, uuid)         from public, anon;
revoke execute on function public.admin_contas()                    from public, anon;
revoke execute on function public.admin_papel(uuid, text)           from public, anon;
revoke execute on function public.admin_revogar(uuid)               from public, anon;

grant execute on function public.admin_pessoas(text)             to authenticated;
grant execute on function public.admin_salvar_inscrito(jsonb)    to authenticated;
grant execute on function public.admin_salvar_responsavel(jsonb) to authenticated;
grant execute on function public.admin_excluir(text, uuid)       to authenticated;
grant execute on function public.admin_contas()                  to authenticated;
grant execute on function public.admin_papel(uuid, text)         to authenticated;
grant execute on function public.admin_revogar(uuid)             to authenticated;

-- ------------------------------------------------------------
-- CRIAR LOGIN NOVO continua sendo:
--
--   1. acrescentar a linha em avaliadores.csv
--   2. node scripts/criar-avaliadores.mjs avaliadores.csv
--   3. na tela de gestão, ajustar o papel se for gestor ou diretoria
--
-- O passo 2 precisa da service_role, que só existe no terminal.
-- ------------------------------------------------------------
