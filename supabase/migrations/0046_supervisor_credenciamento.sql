-- ============================================================
-- 0046 — Supervisor também abre o credenciamento
--
-- A 0043 desenhou o supervisor para a tela do evento: gestão de
-- pessoas, contas de acesso, painel ao vivo. A mesa de entrada
-- ficou de fora porque não tinha sido pedida.
--
-- Foi pedida agora: a supervisão de bilinguismo das unidades
-- também trabalha no credenciamento no dia.
--
-- O QUE ISTO ABRE, E O QUE NÃO ABRE
--
-- exigir_credenciamento() é a guarda de seis funções, todas da
-- mesa de entrada: lista_presenca, marcar_presenca,
-- inscrever_no_local, cracha_avulso, lista_avaliadores e
-- marcar_avaliador. É exatamente o trabalho do balcão.
--
-- Continua fora do alcance do supervisor, porque mora em outra
-- guarda: exportar_inscritos, painel_gestor, lista_palestras e
-- chave_feira (exigir_gestor), e a presença das palestras
-- (exigir_palestras). Nada disso muda aqui.
--
-- Não há perda de privacidade nova: o supervisor já enxerga a
-- base inteira de inscritos pela tela do evento, por decisão
-- registrada na 0043.
-- ============================================================

create or replace function public.exigir_credenciamento()
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
                  where id = v_id
                    and papel in ('atendente', 'supervisor', 'gestor', 'diretoria')) then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;
