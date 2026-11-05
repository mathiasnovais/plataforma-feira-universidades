-- ============================================================
-- 0048 — O cartão dos representantes passa a contar presença
--
-- SINTOMA
--
-- Dois dias depois da feira, o painel "Ao vivo" mostrava:
--
--   ALUNOS DENTRO           70%   332 de 475
--   RESPONSÁVEIS DENTRO     63%   266 de 425
--   COUNSELORS E DOCENTES   18%   2 de 11
--   REPRESENTANTES ATIVOS    2%   1 de 58 · 0 contatos salvos
--
-- Os quatro números estavam certos. O problema é que três deles
-- respondem a uma pergunta e o quarto responde a outra.
--
-- CAUSA
--
-- `presente` é um booleano gravado no credenciamento e nunca
-- zerado: os três primeiros cartões são o acumulado do evento
-- inteiro e continuam iguais para sempre. Já os representantes
-- eram contados numa janela de 12 horas sobre log_acesso e
-- contatos_salvos (0035, mantida na 0036).
--
-- Durante o evento as duas leituras coincidem e ninguém nota. No
-- dia seguinte elas divergem, e a tela passa a mostrar 2% de
-- representantes ao lado de 70% de alunos — o que se lê como
-- painel quebrado, não como "faz 12 horas que ninguém escaneia".
-- Naquele print o "1 ativo" era uma representante que abriu o app
-- às 8h51 da segunda-feira. O número estava certo; a pergunta é
-- que era outra.
--
-- CORREÇÃO
--
-- O cartão passa a contar quem esteve presente, como os demais.
--
-- PRESENÇA DE REPRESENTANTE TEM DUAS EVIDÊNCIAS
--
-- A `avaliadores.presente` (0040) só marca quem passou pela mesa
-- de credenciamento. Nesta edição foram 25 — mas 38 leram crachá
-- no salão. Os 13 de diferença estavam demonstravelmente lá: não
-- se lê um crachá de dentro de casa.
--
-- Então presença aqui é a união das duas: credenciado OU com
-- leitura registrada. Vale durante o evento (o número sobe
-- conforme as pessoas chegam, que é o que um painel ao vivo
-- precisa) e vale depois (vira o total final). `credenciados` sai
-- ao lado para a diferença ficar visível em vez de escondida.
--
-- `leituras` e `contatos` também deixam de ser janela de 12 horas
-- e passam a ser o total do evento, pelo mesmo motivo.
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

    -- ÚNICO bloco diferente da 0036. O resto da função é igual.
    --
    -- O EXISTS fica na subconsulta, não dentro do FILTER: numa
    -- função que só é planejada quando chamada, e chamada só por
    -- conta de diretoria, não é hora de apostar em construção
    -- exótica. Aqui `esteve` é uma coluna booleana comum e o
    -- FILTER recebe o que sempre recebe.
    'reps', (
      select jsonb_build_object(
        'total',        count(*),
        'presentes',    count(*) filter (where p.esteve),
        'credenciados', count(*) filter (where p.presente),
        'leituras',     (select count(*) from log_acesso),
        'contatos',     (select count(*) from contatos_salvos)
      )
      from (
        select av.presente,
               (av.presente
                or exists (select 1 from log_acesso l
                            where l.avaliador_id = av.id)) as esteve
          from avaliadores av
         where av.papel = 'avaliador'
      ) p
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
-- A TELA PRECISA IR JUNTO
--
-- O evento.html lia `reps.ativos`, chave que não existe mais. Sem
-- publicar o HTML novo, o cartão mostra "undefined de 58".
-- Publique os dois na mesma janela.
--
-- CONFERÊNCIA — RODE ANTES DE APLICAR
--
-- `select public.painel_evento()` não serve de teste: o
-- exigir_diretoria() recusa no SQL Editor antes de o corpo ser
-- planejado. Foi assim que a 0035 subiu quebrada. O bloco abaixo é
-- o mesmo SQL do 'reps' novo, sem o guardião — se ele devolver
-- linha, a parte nova da função está sã.
--
--   select jsonb_build_object(
--            'total',        count(*),
--            'presentes',    count(*) filter (where p.esteve),
--            'credenciados', count(*) filter (where p.presente),
--            'leituras',     (select count(*) from public.log_acesso),
--            'contatos',     (select count(*) from public.contatos_salvos))
--     from (
--       select av.presente,
--              (av.presente
--               or exists (select 1 from public.log_acesso l
--                           where l.avaliador_id = av.id)) as esteve
--         from public.avaliadores av
--        where av.papel = 'avaliador'
--     ) p;
--
-- Esperado nesta edição (24/08/2026):
--
--   total 58 · presentes 38 · credenciados 25
--   leituras 1108 · contatos 1003
--
-- Depois de aplicar, o teste de verdade continua sendo abrir a
-- tela com uma conta de diretoria.
-- ------------------------------------------------------------
