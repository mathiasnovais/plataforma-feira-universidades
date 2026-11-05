-- ============================================================
-- 0043 — Dois papéis novos: supervisor e atendente
--
-- SUPERVISOR (supervisão de bilinguismo das unidades)
--   Abre /evento como a diretoria abre: painel ao vivo, pessoas do
--   evento, contas de acesso. A diferença está nas contas — ele
--   CRIA representante e nada além disso. Não muda papel de
--   ninguém, não revoga, não apaga.
--
-- ATENDENTE (equipe externa da mesa de entrada)
--   Abre /credenciamento e só. Nem painel de inscrições, nem
--   exportação, nem gestão.
--
-- POR QUE GUARDA NOVA, E NÃO UM 'or papel = ...' NAS ANTIGAS
--
-- exigir_diretoria() é a primeira linha de nove funções admin_*
-- mais o painel ao vivo. exigir_gestor() é a porta de doze, entre
-- elas exportar_inscritos (a base inteira, com telefone e e-mail
-- de responsável, sem where e sem limit), painel_gestor,
-- lista_palestras e chave_feira — que devolve em texto puro o
-- segredo que protege a inscrição pública no local.
--
-- Acrescentar um papel numa dessas listas entregaria tudo isso de
-- uma vez. As duas guardas antigas não são tocadas aqui: entram
-- duas novas, e cada função escolhe a sua. Se eu tiver esquecido
-- alguma função, o efeito é o papel novo NÃO conseguir usá-la —
-- aparece no teste, e não vaza nada.
--
-- O DEFEITO QUE ISTO CONSERTA DE PASSAGEM
--
-- 1) admin_criar_conta (0042) recebia o papel do navegador e, se o
--    e-mail já existisse, reescrevia o papel de quem já estava lá
--    pelo "on conflict do update". Enquanto só a diretoria
--    alcançava a função, era defeito adormecido. Com o supervisor
--    seria a porta da frente: bastaria digitar o e-mail de um
--    diretor para rebaixá-lo, usando a única função permitida.
--
-- 2) exigir_avaliador() (0003) checava só a EXISTÊNCIA da linha em
--    avaliadores, sem olhar papel — foi escrita antes de a coluna
--    papel existir. Sem conserto, todo supervisor e todo atendente
--    ganharia de brinde o app de escanear crachá, que lê perfil de
--    aluno pelo código impresso. Vira lista branca dos três papéis
--    que já usam o app hoje; ninguém perde acesso.
--
-- OS CORPOS DE FUNÇÃO ABAIXO NÃO FORAM REDIGITADOS
--
-- Postgres não deixa trocar só a primeira linha de uma função:
-- obriga a reescrever inteira. Cada corpo aqui foi extraído por
-- script da migration onde vivia, com uma única troca — a linha da
-- guarda. Nenhuma outra linha mudou.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Os papéis passam a existir
-- ------------------------------------------------------------
alter table public.avaliadores
  drop constraint if exists avaliadores_papel_check;

alter table public.avaliadores
  add constraint avaliadores_papel_check
  check (papel in ('avaliador', 'gestor', 'diretoria', 'supervisor', 'atendente'));

comment on column public.avaliadores.papel is
  'avaliador  = representante de universidade, escaneia crachá. '
  'atendente  = equipe da mesa de entrada, SÓ o credenciamento. '
  'gestor     = organização: painel de inscrições e credenciamento. '
  'supervisor = tela do evento inteira, mas só CRIA conta de '
  'representante — não muda papel, não revoga, não apaga. '
  'diretoria  = tudo.';

-- ------------------------------------------------------------
-- 2. As duas guardas novas
--
-- Função em Postgres nasce com EXECUTE para PUBLIC. Sem o revoke,
-- estas ficariam chamáveis pela REST com a chave anon e virariam
-- um oráculo de "que papel tem esta sessão?".
-- ------------------------------------------------------------
create or replace function public.exigir_credenciamento()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := auth.uid();
begin
  if v_id is null then
    raise exception 'nao_autenticado';
  end if;
  if not exists (select 1 from avaliadores
                  where id = v_id
                    and papel in ('atendente', 'gestor', 'diretoria')) then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;

create or replace function public.exigir_gestao()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := auth.uid();
begin
  if v_id is null then
    raise exception 'nao_autenticado';
  end if;
  if not exists (select 1 from avaliadores
                  where id = v_id
                    and papel in ('supervisor', 'diretoria')) then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;

revoke execute on function public.exigir_credenciamento() from public, anon;
revoke execute on function public.exigir_gestao()         from public, anon;

-- ------------------------------------------------------------
-- 3. exigir_avaliador: de "tem linha?" para "tem papel de app?"
-- ------------------------------------------------------------
create or replace function public.exigir_avaliador()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := auth.uid();
begin
  if v_id is null then
    raise exception 'nao_autenticado';
  end if;
  if not exists (select 1 from avaliadores
                  where id = v_id
                    and papel in ('avaliador', 'gestor', 'diretoria')) then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 4. As seis funções da mesa de entrada
--    exigir_gestor -> exigir_credenciamento
-- ------------------------------------------------------------
create or replace function public.lista_presenca()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_credenciamento();
begin
  return jsonb_build_object(
    'gerado_em', now(),

    'resumo', jsonb_build_object(
      'esperados', (select count(*) from alunos where ativo)
                 + (select count(*) from acompanhantes c
                      join alunos a on a.id = c.aluno_id where a.ativo),
      'presentes', (select count(*) from alunos where ativo and presente)
                 + (select count(*) from acompanhantes c
                      join alunos a on a.id = c.aluno_id where a.ativo and c.presente)
    ),

    'pessoas', coalesce((
      select jsonb_agg(linha order by linha->>'ordem')
        from (
          select jsonb_build_object(
                   'id',       a.id,
                   'kind',     'inscrito',
                   'tipo',     a.tipo,
                   'nome',     a.nome,
                   'detalhe',  nullif(concat_ws(' · ',
                                 nullif(a.ano_escolaridade, ''),
                                 nullif(coalesce(a.unidade, a.colegio), '')), ''),
                   'codigo',   a.codigo_curto,
                   'presente', a.presente,
                   'acompanhantes', (select count(*) from acompanhantes c
                                      where c.aluno_id = a.id),
                   'sem_cracha', a.cracha_lote is null,
                   'origem',   a.origem,
                   'ordem',    public.chave_nome(a.nome)
                 ) as linha
            from alunos a
           where a.ativo

          union all

          select jsonb_build_object(
                   'id',       c.id,
                   'kind',     'acompanhante',
                   'tipo',     'acompanhante',
                   'de',       a.id,
                   'nome',     c.nome,
                   'parentesco', c.parentesco,
                   'detalhe',  concat_ws(' · ',
                                 nullif(c.parentesco, ''),
                                 'acompanha ' || a.nome),
                   'codigo',   a.codigo_curto,
                   'presente', c.presente,
                   'sem_cracha', a.cracha_lote is null,
                   'ordem',    public.chave_nome(c.nome)
                 ) as linha
            from acompanhantes c
            join alunos a on a.id = c.aluno_id
           where a.ativo
        ) q
    ), '[]'::jsonb)
  );
end;
$$;

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
  v_gestor uuid := public.exigir_credenciamento();
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

create or replace function public.inscrever_no_local(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor      uuid := public.exigir_credenciamento();
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

create or replace function public.cracha_avulso(p_kind text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor uuid := public.exigir_credenciamento();
  v_r      record;
begin
  if p_kind = 'inscrito' then
    select a.nome,
           -- Mesmo subtítulo do crachá impresso (gerar-crachas.mjs).
           -- Dois desenhos diferentes para o mesmo evento confundem
           -- quem confere na entrada.
           case
             when a.tipo = 'counselor' then
               'College Counselor · ' || coalesce(a.colegio, a.unidade, 'Instituição não informada')
             when a.tipo = 'docente' then
               'Docente · ' || coalesce(a.colegio, a.unidade, 'Instituição não informada')
             else
               nullif(concat_ws(' · ',
                 nullif(a.ano_escolaridade, ''),
                 case when a.aluno_alfacem is false
                      then coalesce(nullif(a.colegio, ''), 'Colégio externo')
                      else coalesce(nullif(a.unidade, ''), 'Rede Alfacem Global Academy') end), '')
           end as sub,
           a.codigo_curto, a.cracha_token
      into v_r
      from alunos a
     where a.id = p_id and a.ativo;

  elsif p_kind = 'acompanhante' then
    -- O acompanhante carrega o token E o código DO ALUNO: quem
    -- escanear a mãe abre o perfil do filho. Ele não tem perfil
    -- próprio (0012).
    select c.nome,
           'Responsável · ' || coalesce(
             nullif(concat_ws(' · ',
               nullif(a.ano_escolaridade, ''),
               case when a.aluno_alfacem is false
                    then coalesce(nullif(a.colegio, ''), 'Colégio externo')
                    else coalesce(nullif(a.unidade, ''), 'Rede Alfacem Global Academy') end), ''),
             'acompanhante') as sub,
           a.codigo_curto, a.cracha_token
      into v_r
      from acompanhantes c
      join alunos a on a.id = c.aluno_id
     where c.id = p_id and a.ativo;

  else
    raise exception 'kind_invalido';
  end if;

  if v_r.nome is null then
    raise exception 'nao_encontrado';
  end if;

  return jsonb_build_object(
    'nome',   v_r.nome,
    'sub',    coalesce(v_r.sub, ''),
    'codigo', v_r.codigo_curto,
    'token',  v_r.cracha_token
  );
end;
$$;

create or replace function public.lista_avaliadores()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_credenciamento();
begin
  return jsonb_build_object(
    'resumo', (
      select jsonb_build_object(
        'total',     count(*),
        'presentes', count(*) filter (where presente))
        from avaliadores where papel = 'avaliador'
    ),
    'pessoas', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'id',       a.id,
                 'nome',     a.nome,
                 'email',    a.email,
                 'onde',     a.organizacao,
                 'presente', a.presente,
                 'em',       a.presente_em,
                 'por',      (select g.nome from avaliadores g where g.id = a.presente_por))
               order by public.chave_nome(a.nome))
        from avaliadores a
       where a.papel = 'avaliador'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.marcar_avaliador(p_id uuid, p_presente boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor uuid := public.exigir_credenciamento();
begin
  update avaliadores
     set presente     = p_presente,
         presente_em  = case when p_presente then now() else null end,
         presente_por = case when p_presente then v_gestor else null end
   where id = p_id and papel = 'avaliador';

  if not found then
    raise exception 'nao_encontrado';
  end if;

  return jsonb_build_object('ok', true, 'presente', p_presente);
end;
$$;

-- ------------------------------------------------------------
-- 5. A tela do evento
--    exigir_diretoria -> exigir_gestao
--
-- O supervisor enxerga o mesmo que a diretoria aqui: painel ao
-- vivo, busca de pessoas, edição e exclusão de inscrito, e a lista
-- de contas. O que ele não faz está na seção 6.
-- ------------------------------------------------------------
create or replace function public.painel_evento()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_gestao();
begin
  return jsonb_build_object(
    'agora', now(),

    -- Cada público conta separado: 80% dos alunos dentro com 30%
    -- dos responsáveis é uma situação completamente diferente de
    -- 55% e 55%, e a média esconderia isso.
    'alunos', (
      select jsonb_build_object(
        'total',     count(*),
        'presentes', count(*) filter (where presente))
        from alunos where ativo and coalesce(tipo, 'aluno') = 'aluno'
    ),

    'responsaveis', (
      select jsonb_build_object(
        'total',     count(*),
        'presentes', count(*) filter (where c.presente))
        from acompanhantes c join alunos a on a.id = c.aluno_id
       where a.ativo
    ),

    'convidados', (
      select jsonb_build_object(
        'total',     count(*),
        'presentes', count(*) filter (where presente))
        from alunos where ativo and coalesce(tipo, 'aluno') in ('counselor', 'docente')
    ),

    'reps', (
      select jsonb_build_object(
        'total', (select count(*) from avaliadores where papel = 'avaliador'),
        'ativos', (
          select count(distinct l.avaliador_id)
            from log_acesso l
            join avaliadores av on av.id = l.avaliador_id
           where av.papel = 'avaliador'
             and l.em > now() - interval '12 hours'),
        'leituras', (
          select count(*) from log_acesso where em > now() - interval '12 hours'),
        'contatos', (
          select count(*) from contatos_salvos where criado_em > now() - interval '12 hours')
      )
    ),

    -- `quando` viaja ao lado do jsonb só para ordenar. Ordenar
    -- pelo texto de dentro do objeto é o que quebrava.
    'chegando', coalesce((
      select jsonb_agg(linha order by quando desc)
        from (
          select linha, quando
            from (
              select jsonb_build_object(
                       'nome',   a.nome,
                       'quem',   'inscrito',
                       'tipo',   coalesce(a.tipo, 'aluno'),
                       'onde',   coalesce(a.unidade, a.colegio),
                       'em',     a.presente_em,
                       'por',    (select av.nome from avaliadores av where av.id = a.presente_por)
                     ) as linha,
                     a.presente_em as quando
                from alunos a
               where a.presente and a.presente_em is not null

              union all

              select jsonb_build_object(
                       'nome',   c.nome,
                       'quem',   'responsavel',
                       'tipo',   'acompanhante',
                       'onde',   'acompanha ' || a.nome,
                       'em',     c.presente_em,
                       'por',    (select av.nome from avaliadores av where av.id = c.presente_por)
                     ) as linha,
                     c.presente_em as quando
                from acompanhantes c join alunos a on a.id = c.aluno_id
               where c.presente and c.presente_em is not null
            ) u
           order by quando desc
           limit 40
        ) q
    ), '[]'::jsonb),

    -- Blocos de 15 minutos, contados em segundos desde a época.
    -- 900 = 15 * 60. O cast para double precision é explícito
    -- porque to_timestamp recebe double precision e extract
    -- devolve numeric.
    'ritmo', coalesce((
      select jsonb_agg(jsonb_build_object('faixa', faixa, 'n', n) order by faixa)
        from (
          select to_char(
                   to_timestamp((floor(extract(epoch from em) / 900) * 900)::double precision)
                     at time zone 'America/Sao_Paulo',
                   'HH24:MI') as faixa,
                 count(*) as n
            from (
              select presente_em as em from alunos
               where presente and presente_em > now() - interval '3 hours'
              union all
              select presente_em from acompanhantes
               where presente and presente_em > now() - interval '3 hours'
            ) t
           group by 1
        ) q
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_pessoas(p_busca text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_gestao();
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

create or replace function public.admin_salvar_inscrito(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin  uuid := public.exigir_gestao();
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

create or replace function public.admin_salvar_responsavel(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_gestao();
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

create or replace function public.admin_excluir(p_kind text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_gestao();
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

create or replace function public.admin_contas()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_gestao();
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

-- ------------------------------------------------------------
-- 6. As três que continuam SÓ da diretoria
--
-- admin_papel, admin_revogar e admin_apagar_conta não são
-- recriadas aqui: continuam com exigir_diretoria() como estão. A
-- única mudança é a lista de papéis aceitos em admin_papel, para a
-- diretoria conseguir nomear supervisor e atendente pela tela.
-- ------------------------------------------------------------
create or replace function public.admin_papel(p_id uuid, p_papel text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_diretoria();
begin
  if p_papel not in ('avaliador', 'gestor', 'diretoria', 'supervisor', 'atendente') then
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

-- ------------------------------------------------------------
-- 7. admin_criar_conta: com teto de papel
--
-- Reescrita à mão, porque aqui a lógica muda de verdade.
--
-- Três travas novas, todas do lado do banco — a tela esconder o
-- botão não vale como proteção, já que a chave anon está na página
-- e qualquer sessão faz o POST direto na função:
--
--   a) quem não é diretoria só cria 'avaliador';
--   b) quem não é diretoria não escreve por cima de conta que já
--      exista com papel diferente de 'avaliador' — é o que impedia
--      rebaixar um diretor digitando o e-mail dele;
--   c) ninguém que não seja diretoria altera a própria linha.
-- ------------------------------------------------------------
create or replace function public.admin_criar_conta(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_admin  uuid := public.exigir_gestao();
  v_quem   text;
  v_alvo   text;
  v_nome   text := nullif(trim(p_dados->>'nome'), '');
  v_email  text := lower(nullif(trim(p_dados->>'email'), ''));
  v_org    text := nullif(trim(p_dados->>'organizacao'), '');
  v_papel  text := coalesce(nullif(trim(p_dados->>'papel'), ''), 'avaliador');
  v_id     uuid;
  v_novo   boolean := false;
begin
  select papel into v_quem from public.avaliadores where id = v_admin;

  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;
  if v_email is null
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;
  if v_papel not in ('avaliador', 'gestor', 'diretoria', 'supervisor', 'atendente') then
    raise exception 'papel_invalido';
  end if;

  -- (a) teto de papel
  if v_quem is distinct from 'diretoria' and v_papel <> 'avaliador' then
    raise exception 'papel_acima_do_seu';
  end if;

  select id into v_id from auth.users where lower(email) = v_email;

  if v_id is not null and v_quem is distinct from 'diretoria' then
    -- (c) não mexe na própria linha
    if v_id = v_admin then
      raise exception 'nao_altera_a_si';
    end if;
    -- (b) não escreve por cima de conta de outro nível
    select papel into v_alvo from public.avaliadores where id = v_id;
    if v_alvo is not null and v_alvo <> 'avaliador' then
      raise exception 'conta_protegida';
    end if;
  end if;

  if v_id is null then
    v_id := gen_random_uuid();
    v_novo := true;

    insert into auth.users (
      id, instance_id, aud, role, email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) values (
      v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', v_email,
      null,
      now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('nome', v_nome),
      now(), now()
    );
  end if;

  insert into public.avaliadores (id, nome, email, organizacao, papel)
  values (v_id, v_nome, v_email, v_org, v_papel)
  on conflict (id) do update
    set nome = excluded.nome,
        email = excluded.email,
        organizacao = excluded.organizacao,
        papel = excluded.papel;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'nome', v_nome, 'email', v_email,
    'papel', v_papel, 'novo', v_novo);
end;
$$;

-- ------------------------------------------------------------
-- 8. Conferência depois de aplicar
--
--   -- quem é o quê
--   select papel, count(*) from public.avaliadores group by papel order by papel;
--
--   -- a lista de papéis aceita os novos?
--   select pg_get_constraintdef(oid) from pg_constraint
--    where conname = 'avaliadores_papel_check';
--
--   -- cada função está com a guarda certa?
--   select p.proname,
--          case when pg_get_functiondef(p.oid) like '%exigir_credenciamento%' then 'credenciamento'
--               when pg_get_functiondef(p.oid) like '%exigir_gestao%'         then 'gestao'
--               when pg_get_functiondef(p.oid) like '%exigir_diretoria%'      then 'diretoria'
--               when pg_get_functiondef(p.oid) like '%exigir_gestor%'         then 'gestor'
--               when pg_get_functiondef(p.oid) like '%exigir_avaliador%'      then 'avaliador'
--               else '(sem guarda)' end as guarda
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('lista_presenca','marcar_presenca','inscrever_no_local',
--                        'cracha_avulso','lista_avaliadores','marcar_avaliador',
--                        'painel_evento','admin_pessoas','admin_salvar_inscrito',
--                        'admin_salvar_responsavel','admin_excluir','admin_contas',
--                        'admin_papel','admin_revogar','admin_apagar_conta',
--                        'admin_criar_conta','exportar_inscritos','painel_gestor',
--                        'chave_feira','buscar_aluno','salvar_contato')
--    order by guarda, p.proname;
-- ------------------------------------------------------------
