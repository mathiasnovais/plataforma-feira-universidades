-- ============================================================
-- 0028 — A leva do crachá no painel
--
-- A 0027 passou a carimbar quem já teve crachá gerado, mas o
-- carimbo só era visível pelo terminal (`--situacao`) ou por SQL
-- na mão. Quem revisa inscrição trabalha no painel, e a pergunta
-- que aparece ali é sempre a mesma: "esse aluno novo já tem
-- crachá impresso ou ainda vou precisar imprimir?"
--
-- Sem a resposta na tela, a saída natural é imprimir de novo por
-- garantia — que é exatamente o crachá duplicado que a 0027
-- existe para impedir.
--
-- Duas adições:
--   - `cracha_lote` em cada linha de `inscricoes`, para a coluna
--   - `crachas_levas`, os totais, para o cartão do topo
--
-- Nome novo em vez de estender `crachas`: aquele objeto vem do
-- painel_publico() e é mesclado com `||`, que substitui a chave
-- inteira. Reaproveitar o nome apagaria `crachas.total` e o
-- cartão "pessoas no evento" ficaria vazio.
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

    -- Conta crachás, não pessoas inscritas: o acompanhante também
    -- recebe um, e ele herda a leva do aluno (0027). São estes os
    -- números que o `gerar-crachas.mjs --situacao` mostra.
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
                   'cracha_lote', a.cracha_lote,
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
-- O painel mostra a leva de cada inscrito, mas quem gera e
-- desfaz leva continua sendo o scripts/gerar-crachas.mjs. Não
-- há botão de imprimir no painel de propósito: a geração precisa
-- da service_role, e essa chave não pode viver numa página aberta
-- no navegador — ela ignora toda a RLS.
-- ------------------------------------------------------------
