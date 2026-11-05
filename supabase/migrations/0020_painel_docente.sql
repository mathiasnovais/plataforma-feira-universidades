-- ============================================================
-- 0020 — Painel passa a contar o docente à parte
--
-- A 0016 escreveu as contagens quando havia dois tipos, e usou
-- `tipo <> 'counselor'` como sinônimo de "aluno". Com o docente
-- da 0019, essa expressão passou a incluí-lo — e a direção veria
-- docente contado como aluno, na barra da unidade dele.
--
-- Aqui todas as contagens de aluno passam a dizer `tipo = 'aluno'`
-- explicitamente. Ficou mais longo e menos esperto, e é o certo:
-- o que salvou a expressão anterior por um tempo foi só não
-- existir um terceiro tipo.
-- ============================================================

create or replace function public.painel_publico()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'atualizado_em', now(),

    'totais', (
      select jsonb_build_object(
        'inscricoes',   count(*),
        'alunos',       count(*) filter (where tipo = 'aluno'),
        'counselors',   count(*) filter (where tipo = 'counselor'),
        'docentes',     count(*) filter (where tipo = 'docente'),
        'aprovados',    count(*) filter (where ativo),
        'pendentes',    count(*) filter (where not ativo)
      ) from alunos
    ),

    'acompanhantes', (select count(*) from acompanhantes),

    'crachas', jsonb_build_object(
      'total',     (select count(*) from alunos) + (select count(*) from acompanhantes),
      'aprovados', (select count(*) from alunos where ativo)
                 + (select count(*) from acompanhantes c
                     join alunos a on a.id = c.aluno_id where a.ativo)
    ),

    'por_unidade', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by n desc, rotulo), '[]'::jsonb)
        from (select coalesce(unidade, colegio, 'não informado') as rotulo, count(*) as n
                from alunos where tipo = 'aluno'
               group by 1) q
    ),

    'por_ano', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by rotulo), '[]'::jsonb)
        from (select coalesce(ano_escolaridade, 'não informado') as rotulo, count(*) as n
                from alunos where tipo = 'aluno'
               group by 1) q
    ),

    'por_pais', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by n desc, rotulo), '[]'::jsonb)
        from (select unnest(paises_interesse) as rotulo, count(*) as n
                from alunos where tipo = 'aluno' and paises_interesse is not null
               group by 1) q
    ),

    'por_acompanhamento', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by n desc), '[]'::jsonb)
        from (select coalesce(responsavel_acompanha, 'não informado') as rotulo, count(*) as n
                from alunos where tipo = 'aluno'
               group by 1) q
    ),

    -- Counselors e docentes lado a lado: são os dois grupos que
    -- vêm sozinhos, e a direção quer ver de onde vêm.
    'por_instituicao_counselor', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by n desc, rotulo), '[]'::jsonb)
        from (select case when tipo = 'docente' then 'Docente · ' else 'Counselor · ' end
                     || coalesce(colegio, unidade, 'não informado') as rotulo,
                     count(*) as n
                from alunos where tipo in ('counselor', 'docente')
               group by 1) q
    ),

    'por_dia', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by rotulo), '[]'::jsonb)
        from (select to_char(criado_em at time zone 'America/Sao_Paulo', 'YYYY-MM-DD') as rotulo,
                     count(*) as n
                from alunos
               where criado_em > now() - interval '45 days'
               group by 1) q
    )
  );
$$;

-- A 0018 revogou de todo mundo; o create or replace preserva,
-- mas repetir protege caso a função tenha sido recriada à mão.
revoke execute on function public.painel_publico() from public, anon, authenticated;

-- ------------------------------------------------------------
-- painel_gestor: a lista ganha o docente
--
-- Recriada da 0017 com uma diferença: a coluna 'onde' passa a
-- olhar a unidade também, senão a linha do docente sairia vazia.
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
                   'ativo',       a.ativo,
                   'email_enviado', a.email_confirmacao_em is not null,
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
               group by lower(trim(a.nome))
              having count(*) > 1) q
    ),

    'sem_contato', (
      select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'tipo', tipo)
                                order by nome), '[]'::jsonb)
        from alunos
       where coalesce(nullif(trim(responsavel_email), ''), nullif(trim(email), '')) is null
    ),

    'acompanhantes_lista', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', c.nome, 'parentesco', c.parentesco, 'de', a.nome)
               order by a.nome, c.nome), '[]'::jsonb)
        from acompanhantes c join alunos a on a.id = c.aluno_id
    )
  );
end;
$$;

revoke execute on function public.painel_gestor() from public, anon;
grant  execute on function public.painel_gestor() to authenticated;

-- ------------------------------------------------------------
-- Conferir depois de rodar
--
--   -- os três tipos aparecem separados
--   select public.painel_publico()->'totais';
--
-- Espere ver as chaves alunos, counselors e docentes, e a soma
-- delas batendo com 'inscricoes'.
-- ------------------------------------------------------------
