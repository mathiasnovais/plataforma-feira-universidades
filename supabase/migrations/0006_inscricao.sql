-- ============================================================
-- 0006 — Formulário de inscrição público
--
-- O formulário é preenchido pelo responsável antes do evento e
-- alimenta a tabela `alunos`. É a origem do consentimento, então
-- é a parte mais sensível do sistema inteiro.
--
-- DESENHO DE SEGURANÇA
--
-- `alunos` continua com RLS sem policy e sem grant para `anon`.
-- O formulário NÃO escreve na tabela: ele chama uma função
-- SECURITY DEFINER que só faz INSERT e nunca SELECT. Mesmo que
-- alguém abuse do endpoint, não há como ler nada.
--
-- Toda inscrição entra com `ativo = false`. Enquanto não for
-- revisada pela organização:
--   - não sai crachá (gerar-crachas.mjs filtra ativo = true)
--   - não é encontrável (buscar_aluno exige ativo)
-- Ou seja, uma inscrição falsa é inerte até alguém aprovar.
-- ============================================================

-- Data e versão do consentimento vêm do SERVIDOR, nunca do
-- cliente. Registro legal que o navegador pode forjar não tem
-- valor probatório.
create or replace function public.versao_consentimento()
returns text
language sql
immutable
as $$
  select 'v1-2026'::text;
$$;

comment on function public.versao_consentimento() is
  'Mude esta versão sempre que o TEXTO do termo mudar. '
  'Consentimento sem versionamento do texto tem valor fraco.';

-- ------------------------------------------------------------
-- inscrever_aluno(dados)
--
-- Recebe um jsonb para não virar uma função de 14 parâmetros.
-- Ignora qualquer campo que o cliente não deveria controlar:
-- ativo, cracha_token, codigo_curto e a data do consentimento.
-- ------------------------------------------------------------
create or replace function public.inscrever_aluno(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nome        text := nullif(trim(p_dados->>'nome'), '');
  v_resp_nome   text := nullif(trim(p_dados->>'responsavel_nome'), '');
  v_resp_email  text := lower(nullif(trim(p_dados->>'responsavel_email'), ''));
  v_nivel       smallint;
  v_compartilhar boolean := coalesce((p_dados->>'compartilhar_responsavel')::boolean, false);
  v_id          uuid;
begin
  -- ---- validação ----
  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;

  if v_resp_nome is null or v_resp_email is null then
    raise exception 'responsavel_obrigatorio';
  end if;

  if v_resp_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'email_invalido';
  end if;

  -- O consentimento é o motivo de existir deste formulário.
  -- Sem ele marcado, não há inscrição.
  if coalesce((p_dados->>'consentimento_responsavel')::boolean, false) is not true then
    raise exception 'consentimento_obrigatorio';
  end if;

  v_nivel := coalesce((p_dados->>'nivel_compartilhamento')::smallint, 0);
  if v_nivel not between 0 and 3 then
    raise exception 'nivel_invalido';
  end if;

  -- Freio simples contra abuso: uma família com muitos filhos na
  -- feira é plausível; trinta inscrições do mesmo e-mail não é.
  if (select count(*) from alunos where lower(responsavel_email) = v_resp_email) >= 10 then
    raise exception 'limite_de_inscricoes';
  end if;

  -- ---- gravação ----
  insert into alunos (
    nome, turma, projeto, resumo,
    email, telefone, linkedin,
    nivel_compartilhamento,
    consentimento_responsavel, consentimento_versao, consentimento_em,
    responsavel_nome, responsavel_email, responsavel_telefone,
    compartilhar_responsavel,
    ativo
  ) values (
    v_nome,
    nullif(trim(p_dados->>'turma'), ''),
    nullif(trim(p_dados->>'projeto'), ''),
    nullif(trim(p_dados->>'resumo'), ''),
    lower(nullif(trim(p_dados->>'email'), '')),
    nullif(trim(p_dados->>'telefone'), ''),
    nullif(trim(p_dados->>'linkedin'), ''),
    v_nivel,
    true,
    public.versao_consentimento(),  -- servidor
    now(),                          -- servidor
    v_resp_nome,
    v_resp_email,
    nullif(trim(p_dados->>'responsavel_telefone'), ''),
    v_compartilhar,
    false                           -- aguarda revisão da organização
  )
  returning id into v_id;

  -- Devolve o mínimo: confirmação e nada que identifique alguém.
  -- Nem o código do crachá, que só existe depois da aprovação.
  return jsonb_build_object(
    'ok', true,
    'protocolo', upper(substr(replace(v_id::text, '-', ''), 1, 8))
  );
end;
$$;

-- ------------------------------------------------------------
-- Permissões
--
-- Esta é a ÚNICA função do projeto que `anon` pode chamar.
-- Ela só insere. Nenhuma leitura é exposta ao público.
-- ------------------------------------------------------------
revoke execute on function public.versao_consentimento()      from public;
revoke execute on function public.inscrever_aluno(jsonb)      from public;

grant execute on function public.inscrever_aluno(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- Revisão pela organização
--
-- Use no SQL Editor depois de conferir a lista. Nada vira crachá
-- antes disto.
-- ------------------------------------------------------------
comment on column public.alunos.ativo is
  'Inscrições do formulário entram false. A organização revisa e '
  'ativa. Só ativo = true gera crachá e é encontrável pelo app.';

-- Fila de revisão:
--   select nome, turma, projeto, responsavel_nome, responsavel_email,
--          nivel_compartilhamento, compartilhar_responsavel, criado_em
--     from public.alunos where not ativo order by criado_em;
--
-- Aprovar tudo o que foi conferido:
--   update public.alunos set ativo = true where not ativo;
