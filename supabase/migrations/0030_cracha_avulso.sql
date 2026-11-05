-- ============================================================
-- 0030 — Crachá avulso, impresso no balcão
--
-- Quem chega sem estar na lista é inscrito no local (0025) e não
-- tem crachá impresso — a leva já foi para a gráfica dias antes.
-- A credencial física dessa pessoa é uma em branco, com o nome
-- escrito à mão, e isso resolve a identificação visual.
--
-- Só que o nome à mão não é escaneável. Sem QR, o representante
-- de universidade não consegue guardar o contato dela, que é o
-- motivo de o evento existir. A saída é imprimir na hora, em
-- papel comum, uma folha com nome e QR para a pessoa levar junto.
--
-- POR QUE UMA PESSOA POR VEZ
--
-- `lista_presenca()` devolve ~1500 linhas para a tela do
-- credenciamento. Colocar `cracha_token` ali seria despejar 1500
-- chaves de perfil no navegador do balcão, todas de uma vez, para
-- imprimir uma. Aqui o token sai de um em um, no clique de
-- imprimir, e some quando a janela de impressão fecha.
--
-- O token continua sendo o que abre o perfil: quem o tem não
-- precisa do crachá. Por isso a função exige gestor, como todo o
-- resto do credenciamento.
-- ============================================================

create or replace function public.cracha_avulso(p_kind text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor uuid := public.exigir_gestor();
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

revoke execute on function public.cracha_avulso(text, uuid) from public, anon;
grant  execute on function public.cracha_avulso(text, uuid) to authenticated;

comment on function public.cracha_avulso(text, uuid) is
  'Nome, subtítulo, código e token de UMA pessoa, para imprimir '
  'crachá no balcão. Uma por vez de propósito: o token abre o '
  'perfil e não deve circular em lista.';

-- ------------------------------------------------------------
-- QUEM FOI IMPRESSO NO BALCÃO
--
-- A impressão avulsa não carimba `cracha_lote` — ela não é uma
-- leva. Se quiser saber quem entrou pelo balcão e portanto não
-- tem crachá da gráfica:
--
--   select nome, codigo_curto, presente_em
--     from public.alunos
--    where cracha_lote is null and presente
--    order by presente_em;
-- ------------------------------------------------------------
