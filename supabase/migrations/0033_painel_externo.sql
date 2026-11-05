-- ============================================================
-- 0033 — O painel passa a saber quem é de fora
--
-- A etiqueta da tabela de inscrições mostrava dois tipos: aluno e
-- counselor. A 0028 já tinha deixado docente de fora por engano —
-- ele caía no rótulo "aluno" — e mesmo depois de corrigido isso
-- na tela, faltava a outra metade da informação.
--
-- "Aluno externo" não é um `tipo`. É um aluno com
-- `aluno_alfacem = false`: mesma coluna `tipo`, procedência
-- diferente. Sem esse campo, o painel não tem como distinguir o
-- aluno da Rede do aluno do Colégio Militar — e essa distinção
-- importa na revisão, porque as duas populações chegaram por
-- caminhos diferentes e têm cadastros com qualidade diferente.
--
-- A única mudança em relação à 0028 é o campo `externo` em cada
-- linha de `inscricoes`. O resto é cópia.
-- ============================================================

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

    'crachas_levas', (
      select jsonb_build_object(
        'gerados', (select count(*) from alunos where ativo and cracha_lote is not null)
                 + (select count(*) from acompanhantes c
                      join alunos a on a.id = c.aluno_id
                     where a.ativo and a.cracha_lote is not null),
        'na_fila', (select count(*) from alunos where ativo and cracha_lote is null)
                 + (select count(*) from acompanhantes c
                      join alunos a on a.id = c.aluno_id
                     where a.ativo and a.cracha_lote is null),
        'ultima',  (select max(cracha_lote) from alunos)
      )
    ),

    'inscricoes', (
      select coalesce(jsonb_agg(linha order by linha->>'criado_em' desc), '[]'::jsonb)
        from (
          select jsonb_build_object(
                   'tipo',        a.tipo,
                   -- Vem como booleano, e não como um tipo novo:
                   -- procedência e papel são coisas separadas, e
                   -- juntar as duas numa coluna só faria "docente
                   -- externo" precisar de um valor próprio.
                   'externo',     a.aluno_alfacem is false,
                   'nome',        a.nome,
                   'onde',        coalesce(a.colegio, a.unidade),
                   'ano',         a.ano_escolaridade,
                   'responsavel', a.responsavel_nome,
                   'contato',     coalesce(a.responsavel_email, a.email),
                   'acompanhantes', (select count(*) from acompanhantes c where c.aluno_id = a.id),
                   'acompanhantes_nomes', coalesce((
                      select jsonb_agg(c.nome order by c.nome)
                        from acompanhantes c where c.aluno_id = a.id), '[]'::jsonb),
                   'ativo',       a.ativo,
                   'presente',    a.presente,
                   'cracha_lote', a.cracha_lote,
                   'origem',      a.origem,
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
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', nome, 'tipo', tipo, 'externo', aluno_alfacem is false)
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
-- Quem é quem, em números:
--
--   select coalesce(tipo,'aluno') as tipo,
--          case when aluno_alfacem is false then 'externo' else 'rede' end as procedencia,
--          count(*)
--     from public.alunos where ativo
--    group by 1,2 order by 1,2;
-- ------------------------------------------------------------
