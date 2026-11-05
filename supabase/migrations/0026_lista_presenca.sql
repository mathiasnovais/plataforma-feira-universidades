-- ============================================================
-- 0026 — Lista de presença completa
--
-- A 0025 entregou busca por nome: digita, acha, marca. Serve para
-- quem chega e você procura.
--
-- Falta o outro modo de trabalhar, que é o do dia: a lista
-- inteira na tela, você vai riscando, e vê de relance quantos
-- faltam. Sem isso não dá para responder "quem ainda não chegou?"
-- sem exportar para planilha.
--
-- Uma chamada só, tudo de uma vez. Com 600 alunos e 900
-- acompanhantes são ~1500 linhas — uns 120 KB de JSON, que o
-- navegador segura sem esforço. Em troca, filtrar e marcar passam
-- a ser instantâneos, sem ida ao servidor a cada tecla.
--
-- Isso importa no dia: a internet do salão vai estar ruim, com
-- 200 celulares disputando. Lista carregada uma vez e filtrada
-- localmente continua funcionando; busca que consulta a cada
-- letra, não.
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

    -- Inscritos e acompanhantes na mesma lista, ordenados por
    -- nome: na mesa de entrada a pessoa diz o nome dela, não a
    -- categoria em que foi cadastrada.
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
                   'ordem',    public.chave_nome(a.nome)
                 ) as linha
            from alunos a
           where a.ativo

          union all

          select jsonb_build_object(
                   'id',       c.id,
                   'kind',     'acompanhante',
                   'tipo',     'acompanhante',
                   'nome',     c.nome,
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
-- marcar_presenca em lote
--
-- Uma família chega junto: aluno e dois acompanhantes. Marcar de
-- um em um são três idas ao servidor com a internet do salão.
--
-- Recebe pares {kind, id} e devolve quantos mudaram. Continua
-- idempotente: repetir não estraga nada.
-- ------------------------------------------------------------
create or replace function public.marcar_presenca_lote(
  p_itens    jsonb,
  p_presente boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor uuid := public.exigir_gestor();
  v_item   jsonb;
  v_n      integer := 0;
begin
  for v_item in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb))
  loop
    if v_item->>'kind' = 'inscrito' then
      update alunos
         set presente = p_presente,
             presente_em = case when p_presente then now() else null end,
             presente_por = case when p_presente then v_gestor else null end
       where id = (v_item->>'id')::uuid and ativo;
    elsif v_item->>'kind' = 'acompanhante' then
      update acompanhantes c
         set presente = p_presente,
             presente_em = case when p_presente then now() else null end,
             presente_por = case when p_presente then v_gestor else null end
       where c.id = (v_item->>'id')::uuid
         and exists (select 1 from alunos a where a.id = c.aluno_id and a.ativo);
    else
      continue;
    end if;

    if found then v_n := v_n + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'alterados', v_n);
end;
$$;

revoke execute on function public.marcar_presenca_lote(jsonb, boolean) from public, anon;
grant  execute on function public.marcar_presenca_lote(jsonb, boolean) to authenticated;

-- ------------------------------------------------------------
-- DEPOIS DO EVENTO
--
-- Quem faltou:
--
--   select nome, coalesce(unidade, colegio) as onde
--     from public.alunos where ativo and not presente
--    order by nome;
--
-- Taxa de comparecimento por unidade:
--
--   select coalesce(unidade, colegio, '—') as unidade,
--          count(*) filter (where presente) as vieram,
--          count(*)                          as esperados,
--          round(100.0 * count(*) filter (where presente) / count(*), 1) as pct
--     from public.alunos
--    where ativo and tipo = 'aluno'
--    group by 1 order by pct desc;
-- ------------------------------------------------------------
