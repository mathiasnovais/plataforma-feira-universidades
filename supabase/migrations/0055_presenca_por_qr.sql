-- ============================================================
-- 0055 — Feira local: presença pelo QR do crachá
--
-- Na feira local a entrada é mais simples: o aluno chega com o
-- crachá, a mesa aponta a câmera e a presença está marcada. A
-- busca por nome continua existindo para quem esqueceu o crachá.
--
-- POR QUE UMA FUNÇÃO NOVA, E NÃO buscar_aluno + marcar_presenca
--
-- buscar_aluno é do avaliador: registra log_acesso, aplica regra
-- de compartilhamento e devolve contato — nada disso pertence à
-- mesa de entrada. E duas chamadas (achar + marcar) dobram a
-- latência na fila. Aqui é uma viagem só, com a guarda da mesa
-- (exigir_credenciamento) e sem tocar em dado de contato.
--
-- JÁ ESTAVA PRESENTE não é erro: ou o mesmo crachá passou duas
-- vezes (inofensivo), ou há dois papéis com o mesmo QR circulando
-- (grave). A mesa decide olhando a pessoa; a função só avisa e
-- NÃO sobrescreve o horário original — ele é a evidência.
-- ============================================================

create or replace function public.credenciar_por_cracha(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor uuid := public.exigir_credenciamento();
  v alunos%rowtype;
begin
  -- Mesma resolução de código do buscar_aluno (0003): aceita o
  -- token do QR ou o código curto de 6 letras digitado à mão.
  select * into v from alunos
   where ativo
     and (cracha_token = lower(trim(p_codigo))
          or codigo_curto = upper(trim(p_codigo)));

  if not found then
    raise exception 'cracha_nao_encontrado';
  end if;

  if v.presente then
    return jsonb_build_object(
      'ok',          true,
      'ja_estava',   true,
      'id',          v.id,
      'kind',        'inscrito',
      'nome',        v.nome,
      'detalhe',     nullif(concat_ws(' · ',
                       nullif(v.ano_escolaridade, ''),
                       nullif(coalesce(v.unidade, v.colegio), '')), ''),
      'presente_em', v.presente_em
    );
  end if;

  update alunos
     set presente = true, presente_em = now(), presente_por = v_gestor
   where id = v.id;

  return jsonb_build_object(
    'ok',          true,
    'ja_estava',   false,
    'id',          v.id,
    'kind',        'inscrito',
    'nome',        v.nome,
    'detalhe',     nullif(concat_ws(' · ',
                     nullif(v.ano_escolaridade, ''),
                     nullif(coalesce(v.unidade, v.colegio), '')), ''),
    'presente_em', now()
  );
end;
$$;

revoke execute on function public.credenciar_por_cracha(text) from public, anon;
grant  execute on function public.credenciar_por_cracha(text) to authenticated;

-- ------------------------------------------------------------
-- Conferência depois de aplicar:
--
--   select has_function_privilege('anon',
--     'public.credenciar_por_cracha(text)', 'execute');  -- false
-- ------------------------------------------------------------
