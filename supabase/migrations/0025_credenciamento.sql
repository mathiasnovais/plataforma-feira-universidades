-- ============================================================
-- 0025 — Credenciamento: presença e inscrição no dia
--
-- No dia do evento a organização precisa de duas coisas na mesma
-- tela, na mesa de entrada:
--
--   1. achar quem chegou e marcar presença
--   2. inscrever quem apareceu sem ter se inscrito antes
--
-- As duas moram no painel, que já exige login de gestor. Não é
-- tela pública: quem credencia é a organização.
--
-- POR QUE PRESENÇA É COLUNA, E NÃO TABELA
--
-- Presença aqui é um fato único por pessoa: chegou ou não chegou.
-- Não há entrada e saída, nem múltiplos dias. Uma tabela de
-- eventos daria histórico que ninguém vai consultar e um join a
-- mais em toda consulta do dia — no momento em que a fila está
-- andando e a internet é ruim.
--
-- Acompanhante também recebe presença própria: ele tem crachá
-- próprio, entra pela mesma porta, e a lista de quem esteve no
-- prédio precisa incluí-lo.
-- ============================================================

alter table public.alunos
  add column if not exists presente     boolean not null default false,
  add column if not exists presente_em  timestamptz,
  add column if not exists presente_por uuid references public.avaliadores(id);

alter table public.acompanhantes
  add column if not exists presente     boolean not null default false,
  add column if not exists presente_em  timestamptz,
  add column if not exists presente_por uuid references public.avaliadores(id);

comment on column public.alunos.presente_por is
  'Quem marcou a presença. Serve para desempatar quando duas '
  'pessoas credenciam ao mesmo tempo e o número não fecha.';

create index if not exists alunos_presente_idx        on public.alunos (presente);
create index if not exists acompanhantes_presente_idx on public.acompanhantes (presente);

-- Busca por nome na mesa de entrada: a pessoa chega e alguém
-- digita parte do nome. Sem índice, cada tecla varre a tabela.
create index if not exists alunos_busca_nome_idx
  on public.alunos (public.chave_nome(nome));
create index if not exists acompanhantes_busca_nome_idx
  on public.acompanhantes (public.chave_nome(nome));

-- ------------------------------------------------------------
-- credenciamento_buscar(termo)
--
-- Devolve alunos, counselors, docentes E acompanhantes numa
-- lista só — na mesa de entrada ninguém sabe de antemão em que
-- categoria a pessoa está.
--
-- Busca por pedaço do nome, sem acento e sem caixa, para
-- funcionar com o que a pessoa fala e alguém digita rápido.
--
-- Só quem está aprovado aparece: inscrição pendente de revisão
-- não tem crachá, e credenciar quem não foi aprovado criaria
-- entrada sem crachá.
-- ------------------------------------------------------------
create or replace function public.credenciamento_buscar(p_termo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id    uuid := public.exigir_gestor();
  v_termo text := lower(trim(coalesce(p_termo, '')));
begin
  if length(v_termo) < 2 then
    return '[]'::jsonb;
  end if;

  -- translate() em vez de unaccent(): o unaccent vive no schema
  -- `extensions` e esta função fixa search_path.
  v_termo := translate(v_termo,
    'áàâãäéèêëíìîïóòôõöúùûüñç',
    'aaaaaeeeeiiiiooooouuuunc');

  return coalesce((
    select jsonb_agg(linha order by linha->>'nome')
      from (
        select jsonb_build_object(
                 'id',        a.id,
                 'kind',      'inscrito',
                 'tipo',      a.tipo,
                 'nome',      a.nome,
                 'detalhe',   coalesce(a.ano_escolaridade || ' · ', '')
                              || coalesce(a.unidade, a.colegio, ''),
                 'codigo',    a.codigo_curto,
                 'presente',  a.presente,
                 'presente_em', a.presente_em
               ) as linha
          from alunos a
         where a.ativo
           and translate(lower(a.nome), 'áàâãäéèêëíìîïóòôõöúùûüñç',
                                        'aaaaaeeeeiiiiooooouuuunc') like '%' || v_termo || '%'

        union all

        select jsonb_build_object(
                 'id',        c.id,
                 'kind',      'acompanhante',
                 'tipo',      'acompanhante',
                 'nome',      c.nome,
                 'detalhe',   coalesce(c.parentesco || ' · ', '') || 'acompanha ' || a.nome,
                 'codigo',    a.codigo_curto,
                 'presente',  c.presente,
                 'presente_em', c.presente_em
               ) as linha
          from acompanhantes c
          join alunos a on a.id = c.aluno_id
         where a.ativo
           and translate(lower(c.nome), 'áàâãäéèêëíìîïóòôõöúùûüñç',
                                        'aaaaaeeeeiiiiooooouuuunc') like '%' || v_termo || '%'
        limit 40
      ) q
  ), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------------
-- marcar_presenca(kind, id, presente)
--
-- Idempotente: marcar duas vezes não muda nada além do horário
-- de quem marcou por último. Na mesa de entrada, com fila
-- andando, o mesmo botão vai ser clicado duas vezes.
--
-- Desmarcar existe porque erro de clique acontece e a pessoa
-- ainda está na frente do balcão.
-- ------------------------------------------------------------
create or replace function public.marcar_presenca(
  p_kind     text,
  p_id       uuid,
  p_presente boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor uuid := public.exigir_gestor();
begin
  if p_kind = 'inscrito' then
    update alunos
       set presente = p_presente,
           presente_em = case when p_presente then now() else null end,
           presente_por = case when p_presente then v_gestor else null end
     where id = p_id and ativo;
  elsif p_kind = 'acompanhante' then
    update acompanhantes c
       set presente = p_presente,
           presente_em = case when p_presente then now() else null end,
           presente_por = case when p_presente then v_gestor else null end
     where c.id = p_id
       and exists (select 1 from alunos a where a.id = c.aluno_id and a.ativo);
  else
    raise exception 'kind_invalido';
  end if;

  if not found then
    raise exception 'nao_encontrado';
  end if;

  return jsonb_build_object('ok', true, 'presente', p_presente);
end;
$$;

-- ------------------------------------------------------------
-- inscrever_no_local(dados)
--
-- Quem aparece no dia sem ter se inscrito. Formulário curto: só o
-- que a mesa consegue perguntar com fila esperando.
--
-- Entra JÁ APROVADO e JÁ PRESENTE — a pessoa está ali, na frente
-- de quem cadastrou. Passar pela revisão não faria sentido: a
-- revisão existe para filtrar inscrição de origem desconhecida,
-- e esta tem origem conhecida por definição.
--
-- Não exige termo de ciência na tela. O consentimento é colhido
-- no balcão, em papel ou verbalmente, e fica registrado como
-- versão própria — para que a diferença apareça na auditoria em
-- vez de se misturar com quem aceitou o termo online.
-- ------------------------------------------------------------
create or replace function public.inscrever_no_local(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor      uuid := public.exigir_gestor();
  v_tipo        text := coalesce(nullif(trim(p_dados->>'tipo'), ''), 'aluno');
  v_nome        text := nullif(trim(p_dados->>'nome'), '');
  v_onde        text := nullif(trim(p_dados->>'onde'), '');
  v_ano         text := nullif(trim(p_dados->>'ano'), '');
  v_resp_nome   text := nullif(trim(p_dados->>'responsavel_nome'), '');
  v_resp_email  text := lower(nullif(trim(p_dados->>'responsavel_email'), ''));
  v_resp_tel    text := nullif(trim(p_dados->>'responsavel_telefone'), '');
  v_da_rede     boolean := coalesce((p_dados->>'da_rede')::boolean, true);
  v_id          uuid;
  v_acomp       jsonb;
  v_acomp_nome  text;
begin
  if v_tipo not in ('aluno', 'counselor', 'docente') then
    raise exception 'tipo_invalido';
  end if;
  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;
  if v_resp_email is not null
     and v_resp_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;

  insert into alunos (
    tipo, nome, ano_escolaridade, aluno_alfacem,
    unidade, colegio,
    responsavel_nome, responsavel_email, responsavel_telefone,
    nivel_compartilhamento,
    consentimento_responsavel, consentimento_versao, consentimento_em,
    ciencia_compartilhamento,
    ativo, presente, presente_em, presente_por,
    -- Não entra na fila de e-mail: a pessoa está no balcão, já
    -- recebeu a informação, e mandar "inscrição confirmada" para
    -- quem acabou de ser credenciado é ruído.
    email_confirmacao_em
  ) values (
    v_tipo, v_nome, v_ano, v_da_rede,
    case when v_da_rede then v_onde else null end,
    case when v_da_rede then null else v_onde end,
    v_resp_nome, v_resp_email, v_resp_tel,
    3::smallint,
    true, 'presencial-' || public.versao_consentimento(), now(),
    true,
    true, true, now(), v_gestor,
    now()
  )
  returning id into v_id;

  for v_acomp in
    select * from jsonb_array_elements(coalesce(p_dados->'acompanhantes', '[]'::jsonb))
  loop
    v_acomp_nome := nullif(trim(v_acomp->>'nome'), '');
    continue when v_acomp_nome is null;

    insert into acompanhantes (aluno_id, nome, parentesco, presente, presente_em, presente_por)
    values (v_id, v_acomp_nome, nullif(trim(v_acomp->>'parentesco'), ''),
            true, now(), v_gestor);
  end loop;

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'codigo', (select codigo_curto from alunos where id = v_id),
    'protocolo', upper(substr(replace(v_id::text, '-', ''), 1, 8))
  );
end;
$$;

revoke execute on function public.credenciamento_buscar(text)                from public, anon;
revoke execute on function public.marcar_presenca(text, uuid, boolean)       from public, anon;
revoke execute on function public.inscrever_no_local(jsonb)                  from public, anon;
grant  execute on function public.credenciamento_buscar(text)                to authenticated;
grant  execute on function public.marcar_presenca(text, uuid, boolean)       to authenticated;
grant  execute on function public.inscrever_no_local(jsonb)                  to authenticated;

-- ------------------------------------------------------------
-- painel_gestor: números de presença e a lista de acompanhantes
-- por inscrição, para o painel mostrar quem são
-- ------------------------------------------------------------
create or replace function public.painel_gestor()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_gestor();
begin
  return public.painel_publico() || jsonb_build_object(

    'presenca', (
      select jsonb_build_object(
        'inscritos_presentes',     (select count(*) from alunos where ativo and presente),
        'inscritos_aprovados',     (select count(*) from alunos where ativo),
        'acompanhantes_presentes', (select count(*) from acompanhantes c
                                      join alunos a on a.id = c.aluno_id
                                     where a.ativo and c.presente),
        'acompanhantes_aprovados', (select count(*) from acompanhantes c
                                      join alunos a on a.id = c.aluno_id where a.ativo)
      )
    ),

    'inscricoes', (
      select coalesce(jsonb_agg(linha order by linha->>'criado_em' desc), '[]'::jsonb)
        from (
          select jsonb_build_object(
                   'tipo',        a.tipo,
                   'nome',        a.nome,
                   'onde',        coalesce(a.colegio, a.unidade),
                   'ano',         a.ano_escolaridade,
                   'responsavel', a.responsavel_nome,
                   'contato',     coalesce(a.responsavel_email, a.email),
                   'acompanhantes', (select count(*) from acompanhantes c where c.aluno_id = a.id),
                   -- Os nomes, para o painel mostrar ao passar o
                   -- mouse em vez de só o número.
                   'acompanhantes_nomes', coalesce((
                      select jsonb_agg(c.nome order by c.nome)
                        from acompanhantes c where c.aluno_id = a.id), '[]'::jsonb),
                   'ativo',       a.ativo,
                   'presente',    a.presente,
                   'email_enviado', a.email_confirmacao_em is not null,
                   'email_erro',    a.email_erro,
                   'email_tentativas', a.email_tentativas,
                   'criado_em',   a.criado_em
                 ) as linha
            from alunos a
           order by a.criado_em desc
           limit 500
        ) q
    ),

    'duplicatas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', nome, 'vezes', vezes, 'contatos', contatos)
               order by vezes desc), '[]'::jsonb)
        from (select min(a.nome) as nome, count(*) as vezes,
                     string_agg(distinct coalesce(a.responsavel_email, a.email), ' · ') as contatos
                from alunos a
               where a.nome is not null and trim(a.nome) <> ''
               group by public.chave_nome(a.nome)
              having count(*) > 1) q
    ),

    'sem_contato', (
      select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'tipo', tipo)
                                order by nome), '[]'::jsonb)
        from alunos
       where coalesce(nullif(trim(responsavel_email), ''), nullif(trim(email), '')) is null
    ),

    'email_travado', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', nome, 'tipo', tipo,
               'destino', coalesce(responsavel_email, email),
               'tentativas', email_tentativas,
               'erro', email_erro)
               order by criado_em), '[]'::jsonb)
        from alunos
       where email_confirmacao_em is null
         and (email_tentativas >= 5
              or email_erro is not null
              or coalesce(case when tipo = 'aluno' then responsavel_email else email end, '')
                 !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$')
    ),

    'acompanhantes_lista', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', c.nome, 'parentesco', c.parentesco, 'de', a.nome,
               'presente', c.presente)
               order by a.nome, c.nome), '[]'::jsonb)
        from acompanhantes c join alunos a on a.id = c.aluno_id
    )
  );
end;
$$;

revoke execute on function public.painel_gestor() from public, anon;
grant  execute on function public.painel_gestor() to authenticated;

-- ------------------------------------------------------------
-- DEPOIS DO EVENTO: a lista de presença
--
--   select tipo, nome,
--          coalesce(unidade, colegio) as onde,
--          presente,
--          presente_em at time zone 'America/Sao_Paulo' as chegou
--     from public.alunos where ativo
--    union all
--   select 'acompanhante', c.nome, 'acompanha ' || a.nome,
--          c.presente, c.presente_em at time zone 'America/Sao_Paulo'
--     from public.acompanhantes c join public.alunos a on a.id = c.aluno_id
--    where a.ativo
--    order by presente desc, nome;
--
-- Quantos vieram:
--
--   select count(*) filter (where presente) as compareceram,
--          count(*)                          as esperados
--     from public.alunos where ativo;
-- ------------------------------------------------------------
