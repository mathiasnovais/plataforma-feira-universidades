-- ------------------------------------------------------------
-- Nome da instituição: "Rede Alfacem Global Academy"
--
-- A perfil_aluno devolve o nome da escola para o app dos
-- avaliadores quando o aluno é da rede e não tem unidade
-- registrada. Estava 'Alfacem Global Academy'.
--
-- É só o rótulo exibido: nenhuma coluna guarda esse texto, então
-- não há nada para corrigir retroativamente nas inscrições que
-- já entraram.
--
-- Recriada por inteiro porque create or replace não aceita
-- alteração parcial. Copiada da 0007, com uma única string
-- diferente — a da linha 'escola'.
-- ------------------------------------------------------------

create or replace function public.perfil_aluno(a public.alunos, p_ja_salvo boolean)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'aluno_id',     a.id,
    'nome',         a.nome,
    'codigo_curto', a.codigo_curto,
    'nivel',        public.nivel_efetivo(a),

    -- contexto escolar
    'escola',       case when public.nivel_efetivo(a) >= 1
                         then coalesce(a.colegio,
                                       case when a.aluno_alfacem
                                            then 'Rede Alfacem Global Academy' end) end,
    'unidade',      case when public.nivel_efetivo(a) >= 1 then a.unidade end,
    'segmento',     case when public.nivel_efetivo(a) >= 1 then a.segmento end,
    'ano',          case when public.nivel_efetivo(a) >= 1 then a.ano_escolaridade end,

    -- qualificação
    'paises',       case when public.nivel_efetivo(a) >= 1 then to_jsonb(a.paises_interesse) end,
    'motivo',       case when public.nivel_efetivo(a) >= 1 then a.motivo end,
    'experiencia',  case when public.nivel_efetivo(a) >= 1 then a.experiencia_internacional end,
    'pathway',      case when public.nivel_efetivo(a) >= 1 then a.conhece_pathway end,

    -- contato do aluno
    'email',        case when public.nivel_efetivo(a) >= 2 then a.email end,

    -- contato do responsável: autorização independente
    'parentesco',           case when public.responsavel_liberado(a) then a.parentesco           end,
    'responsavel_nome',     case when public.responsavel_liberado(a) then a.responsavel_nome     end,
    'responsavel_email',    case when public.responsavel_liberado(a) then a.responsavel_email    end,
    'responsavel_telefone', case when public.responsavel_liberado(a) then a.responsavel_telefone end,

    'pode_salvar',  public.pode_salvar(a),
    'ja_salvo',     p_ja_salvo
  );
$$;

-- ------------------------------------------------------------
-- ANTES DE RODAR
--
-- Este arquivo reproduz a perfil_aluno como ela está na 0007.
-- Se alguma migration posterior tiver mexido nela, esta aqui
-- sobrescreve o que veio depois. Confira o corpo atual:
--
--   select prosrc from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname = 'perfil_aluno';
--
-- DEPOIS DE RODAR
--
--   select public.perfil_aluno(a, false)->>'escola'
--     from public.alunos a
--    where a.aluno_alfacem and a.unidade is null and a.colegio is null
--    limit 1;                    -- Rede Alfacem Global Academy
--
-- Se não houver aluno nessas condições a consulta volta vazia, e
-- isso não é erro: quem tem unidade registrada mostra a unidade,
-- não o nome da rede.
-- ------------------------------------------------------------
