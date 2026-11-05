-- ============================================================
-- 0035 — Painel do evento, ao vivo, para a diretoria
--
-- Pedido do dia: acompanhar de qualquer lugar quanto do público
-- já entrou, quantos representantes chegaram e quem está sendo
-- credenciado neste momento.
--
-- É uma tela de leitura. Não marca presença, não cadastra, não
-- imprime — quem faz isso é a mesa. Aqui só se olha.
--
-- UM PAPEL NOVO: 'diretoria'
--
-- `gestor` hoje é a mesa de entrada, o marketing e a direção. Os
-- números do evento inteiro, com nome de quem está chegando em
-- tempo real, não precisam estar abertos para todos eles.
--
-- diretoria contém gestor: quem tem o papel novo continua abrindo
-- o painel de inscrições e o credenciamento. O contrário não vale.
--
-- COMO SE MEDE "REPRESENTANTE QUE CHEGOU"
--
-- Avaliador não faz check-in: ele entra pelo próprio app e começa
-- a escanear. O sinal de que está no salão é ter escaneado
-- alguém — `log_acesso` (0001) registra cada leitura.
--
-- É uma aproximação, e ela erra por baixo: quem chegou e ainda
-- não escaneou ninguém não aparece. Nos primeiros minutos o
-- número vai estar atrás da realidade. Preferi assim a inventar
-- um check-in de avaliador que ninguém vai lembrar de fazer.
-- ============================================================

alter table public.avaliadores
  drop constraint if exists avaliadores_papel_check;

alter table public.avaliadores
  add constraint avaliadores_papel_check
  check (papel in ('avaliador', 'gestor', 'diretoria'));

comment on column public.avaliadores.papel is
  'avaliador = representante de universidade, escaneia crachá. '
  'gestor = organização, enxerga painel e credenciamento. '
  'diretoria = gestor + painel do evento ao vivo.';

-- ------------------------------------------------------------
-- diretoria contém gestor
--
-- Sem isto, promover alguém a diretoria tiraria dela o acesso ao
-- painel e ao credenciamento — o contrário do pretendido.
-- ------------------------------------------------------------
create or replace function public.exigir_gestor()
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
                  where id = v_id and papel in ('gestor', 'diretoria')) then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;

create or replace function public.exigir_diretoria()
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
  if not exists (select 1 from avaliadores where id = v_id and papel = 'diretoria') then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- painel_evento(): tudo numa chamada só
--
-- A tela consulta a cada 20 segundos. Uma chamada por atualização,
-- e não seis, porque quem abre isso está no celular, muitas vezes
-- fora do salão e em rede de operadora.
-- ------------------------------------------------------------
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

    -- Representantes de universidade. `ativos` é quem já escaneou
    -- alguém — ver o comentário no topo sobre o que isso mede.
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

    -- Quem está sendo credenciado agora, e por quem. As duas
    -- perguntas numa lista só: o nome de quem chegou e o nome de
    -- quem marcou, que é como a direção acompanha o ritmo da mesa.
    'chegando', coalesce((
      select jsonb_agg(linha order by linha->>'em' desc)
        from (
          select jsonb_build_object(
                   'nome',   a.nome,
                   'quem',   'inscrito',
                   'tipo',   coalesce(a.tipo, 'aluno'),
                   'onde',   coalesce(a.unidade, a.colegio),
                   'em',     a.presente_em,
                   'por',    (select av.nome from avaliadores av where av.id = a.presente_por)
                 ) as linha
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
                 ) as linha
            from acompanhantes c join alunos a on a.id = c.aluno_id
           where c.presente and c.presente_em is not null

          order by 1 -> 'em' desc
          limit 40
        ) q
    ), '[]'::jsonb),

    -- Ritmo: quantos entraram em cada bloco de 15 minutos nas
    -- últimas 3 horas. É o que diz se a fila está crescendo ou
    -- passando.
    'ritmo', coalesce((
      select jsonb_agg(jsonb_build_object('faixa', faixa, 'n', n) order by faixa)
        from (
          select to_char(date_trunc('hour', em)
                   + interval '15 min' * floor(extract(minute from em) / 15),
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

revoke execute on function public.painel_evento()   from public, anon;
revoke execute on function public.exigir_diretoria() from public, anon;
grant  execute on function public.painel_evento()   to authenticated;

-- ------------------------------------------------------------
-- DAR ACESSO À DIRETORIA
--
-- As duas pessoas precisam já existir em `avaliadores` — se não
-- existirem, crie antes com scripts/criar-avaliadores.mjs.
--
--   update public.avaliadores set papel = 'diretoria'
--    where email in ('direcao@exemplo.edu.br',
--                    'usuario1@exemplo.edu.br')
--   returning nome, email, papel;
--
-- Conferir quem tem cada papel:
--
--   select papel, count(*), string_agg(email, ', ')
--     from public.avaliadores group by papel order by papel;
-- ------------------------------------------------------------
