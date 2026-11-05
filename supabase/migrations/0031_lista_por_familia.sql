-- ============================================================
-- 0031 — A lista do dia agrupada por família
--
-- A 0026 devolve inscritos e acompanhantes na mesma lista plana,
-- ordenados por nome. Faz sentido para procurar alguém que diz o
-- próprio nome no balcão, mas não é como a fila chega: chega uma
-- família junta, e quem credencia marca o aluno e os dois
-- responsáveis na sequência, procurando três vezes na mesma lista
-- de 1500 linhas.
--
-- A tela passa a listar só quem tem inscrição própria — aluno,
-- aluno externo, college counselor e docente — e a abrir os
-- responsáveis de cada um num popup, para marcar um a um.
--
-- O QUE FALTAVA NO BANCO
--
-- O acompanhante saía com 'detalhe' = "Mãe · acompanha João
-- Silva" e nada mais. Agrupar por esse texto significaria casar
-- pessoas pelo nome do aluno escrito por extenso — e o painel já
-- acusa 16 grupos de nomes repetidos neste evento. Duas famílias
-- com um "João Silva" cada trocariam de responsáveis.
--
-- Agora o acompanhante carrega `de`, que é o id do aluno. O
-- vínculo passa a ser o mesmo que existe no banco, não uma
-- semelhança de texto.
-- ============================================================

create or replace function public.lista_presenca()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_gestor();
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
                   -- Quantos responsáveis vêm com esta pessoa, para
                   -- a linha da lista já avisar antes de abrir.
                   'acompanhantes', (select count(*) from acompanhantes c
                                      where c.aluno_id = a.id),
                   'ordem',    public.chave_nome(a.nome)
                 ) as linha
            from alunos a
           where a.ativo

          union all

          select jsonb_build_object(
                   'id',       c.id,
                   'kind',     'acompanhante',
                   'tipo',     'acompanhante',
                   -- `de` é o vínculo de verdade: o id do aluno.
                   -- É o que permite abrir os responsáveis certos
                   -- mesmo quando dois alunos têm o mesmo nome.
                   'de',       a.id,
                   'nome',     c.nome,
                   'parentesco', c.parentesco,
                   'detalhe',  concat_ws(' · ',
                                 nullif(c.parentesco, ''),
                                 'acompanha ' || a.nome),
                   'codigo',   a.codigo_curto,
                   'presente', c.presente,
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

revoke execute on function public.lista_presenca() from public, anon;
grant  execute on function public.lista_presenca() to authenticated;

-- ------------------------------------------------------------
-- Os acompanhantes continuam vindo na mesma lista, e não numa
-- chamada separada por aluno.
--
-- Buscar os responsáveis a cada popup seria uma ida ao servidor
-- com a família parada na frente — e a internet do salão é o
-- maior risco conhecido deste projeto. Tudo desce numa chamada
-- só, no início do dia, e o popup monta a partir do que já está
-- na memória.
-- ------------------------------------------------------------
