-- ============================================================
-- 0036 — Correção do painel_evento da 0035
--
-- A função da 0035 é criada sem erro e explode ao ser chamada:
-- plpgsql só valida a sintaxe do corpo na criação, e o SQL de
-- dentro é planejado na hora da execução. Dois defeitos passaram
-- por isso.
--
-- 1. `order by 1 -> 'em' desc`
--
--    Dentro de ORDER BY, um `1` sozinho é a posição da coluna.
--    Aqui ele estava dentro de uma expressão, então virou o
--    número inteiro 1 — e não existe operador `->` para inteiro.
--
--    Corrigido carregando `presente_em` como coluna própria ao
--    lado do jsonb, e ordenando por ela. Também resolve a
--    restrição de ORDER BY depois de UNION, que só aceita nome ou
--    posição de coluna de saída, não expressão.
--
-- 2. `interval '15 min' * floor(extract(minute from em) / 15)`
--
--    `extract` devolve numeric no Postgres 14+, e não existe
--    operador `interval * numeric` — só `interval * double
--    precision`. Trocado por uma conta em segundos com cast
--    explícito, que não depende de resolução de operador.
--
-- O resto da função é igual à 0035.
-- ============================================================

create or replace function public.painel_evento()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_diretoria();
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

revoke execute on function public.painel_evento() from public, anon;
grant  execute on function public.painel_evento() to authenticated;

-- ------------------------------------------------------------
-- COMO TESTAR O CORPO
--
-- `select public.painel_evento()` no SQL Editor NÃO serve de
-- teste: exigir_diretoria() roda primeiro e levanta
-- `nao_autenticado` antes de o resto ser planejado. Foi
-- exatamente assim que os dois defeitos da 0035 passaram
-- despercebidos.
--
-- Para exercitar o SQL de dentro, rode as partes soltas — sem o
-- guardião, elas revelam qualquer erro de operador ou de ORDER BY:
--
--   select jsonb_agg(linha order by quando desc)
--     from (
--       select jsonb_build_object('nome', a.nome, 'em', a.presente_em) as linha,
--              a.presente_em as quando
--         from public.alunos a
--        where a.presente and a.presente_em is not null
--        limit 40
--     ) q;
--
--   select to_char(
--            to_timestamp((floor(extract(epoch from presente_em) / 900) * 900)::double precision)
--              at time zone 'America/Sao_Paulo', 'HH24:MI') as faixa,
--          count(*)
--     from public.alunos where presente and presente_em is not null
--    group by 1 order by 1;
--
-- As duas devolvendo linhas (ou vazio, sem erro) significam que o
-- corpo está são. O teste de verdade continua sendo abrir a tela
-- com uma conta de diretoria.
-- ------------------------------------------------------------
