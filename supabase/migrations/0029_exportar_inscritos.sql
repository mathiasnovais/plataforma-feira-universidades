-- ============================================================
-- 0029 — Exportação dos inscritos para planilha
--
-- O painel mostra a lista na tela, mas quem trabalha com ela fora
-- do evento — secretaria, coordenação, gráfica — trabalha em
-- planilha. Até aqui a saída era o Table Editor do Supabase, que
-- exporta a tabela crua: com token de crachá, com colunas
-- internas e sem os acompanhantes.
--
-- POR QUE NÃO REAPROVEITAR painel_gestor()
--
-- A lista de `inscricoes` dele tem `limit 500`, que existe para a
-- tela não carregar 1500 linhas a cada atualização. Numa
-- exportação esse limite é veneno: passaria de 500 e o arquivo
-- sairia curto, sem erro nenhum, e ninguém compara a contagem
-- antes de mandar para a gráfica.
--
-- O QUE NÃO SAI AQUI
--
-- `cracha_token` fica de fora de propósito. Ele é a chave que
-- abre o perfil do aluno no app — quem tem o token não precisa do
-- crachá. Planilha é feita para circular por e-mail e Drive; é o
-- último lugar onde esse valor deveria estar. Quem precisa
-- identificar uma linha usa `codigo_curto`, que é público no
-- crachá impresso e não abre nada sozinho.
-- ============================================================

create or replace function public.exportar_inscritos()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_gestor();
begin
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'tipo',            coalesce(a.tipo, 'aluno'),
               'nome',            a.nome,
               'ano',             a.ano_escolaridade,
               'origem',          case when a.aluno_alfacem is false then 'Externo' else 'Rede' end,
               'unidade',         a.unidade,
               'colegio',         a.colegio,
               'responsavel',     a.responsavel_nome,
               'resp_email',      a.responsavel_email,
               'resp_telefone',   a.responsavel_telefone,
               'email',           a.email,
               'telefone',        a.telefone,
               'paises',          array_to_string(a.paises_interesse, ', '),
               'acompanhantes',   (select count(*) from acompanhantes c where c.aluno_id = a.id),
               'acompanhantes_nomes', coalesce((
                                    select string_agg(c.nome, ', ' order by c.nome)
                                      from acompanhantes c where c.aluno_id = a.id), ''),
               'consentimento',   case when a.consentimento_responsavel then 'sim' else 'não' end,
               'aprovado',        case when a.ativo then 'sim' else 'não' end,
               'cracha_leva',     a.cracha_lote,
               'presente',        case when a.presente then 'sim' else 'não' end,
               'codigo',          a.codigo_curto,
               'inscrito_em',     to_char(a.criado_em at time zone 'America/Sao_Paulo',
                                          'DD/MM/YYYY HH24:MI')
             )
             -- Mesma ordenação da lista de presença (0026): pelo
             -- nome sem acento, senão 'Ávila' cai depois de 'Zuza'
             -- e quem procura na planilha não acha.
             order by public.chave_nome(a.nome))
      from alunos a
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.exportar_inscritos() from public, anon;
grant  execute on function public.exportar_inscritos() to authenticated;

comment on function public.exportar_inscritos() is
  'Todos os inscritos, sem limite de linhas, para exportação em '
  'planilha pelo painel. Não devolve cracha_token de propósito.';

-- ------------------------------------------------------------
-- Sai TUDO, inclusive quem ainda não foi aprovado — a coluna
-- `aprovado` diz quem é quem. É o que a revisão precisa: a
-- planilha serve justamente para conferir a fila antes de
-- aprovar, e filtrar no Excel é um clique.
-- ------------------------------------------------------------
