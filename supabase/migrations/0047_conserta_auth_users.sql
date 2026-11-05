-- ============================================================
-- 0047 — Conserto urgente: "Database error finding user"
--
-- SINTOMA
--
-- O avaliador digita o e-mail, pede o código, e o Supabase devolve
-- HTTP 500 "Database error finding user". A pessoa não entra. A
-- listagem de usuários do painel de administração falha junto,
-- com "Database error finding users".
--
-- CAUSA
--
-- admin_criar_conta (0042 em diante) insere direto em auth.users
-- listando só as colunas que interessavam ao cadastro. As demais
-- ficaram NULAS — e o GoTrue, que é escrito em Go, lê
-- confirmation_token, recovery_token e as colunas de troca de
-- e-mail e de telefone como TEXTO. Texto nulo não converte em Go,
-- e a leitura da linha inteira falha.
--
-- A conta existe, está confirmada e é válida. Ela só não pode ser
-- LIDA. Por isso o erro aparece no login e na listagem, mas nunca
-- na criação: quem grava é o Postgres, que aceita nulo; quem
-- quebra é o GoTrue, que depois tenta ler.
--
-- A 0042 avisou, no próprio cabeçalho, que escrever em auth.users
-- é prática comum mas não é interface oficial, e que o preço viria
-- em forma de erro estranho. Veio.
--
-- DUAS PARTES
--
--   1. Reparar as linhas que já estão assim.
--   2. Fazer a função parar de criar linhas novas com o defeito.
--
-- Rodar duas vezes não faz mal: a parte 1 só toca no que está
-- nulo, e a parte 2 é create or replace.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Reparo das linhas existentes
--
-- Coluna a coluna, e só se a coluna existir. A lista de campos de
-- auth.users muda entre versões do Supabase, e uma coluna ausente
-- derrubaria a migration inteira — no meio do evento, com gente
-- esperando para entrar. O que não existir é ignorado em silêncio.
-- ------------------------------------------------------------
do $reparo$
declare
  v_col text;
  v_n   integer;
  v_tot integer := 0;
begin
  foreach v_col in array array[
    'confirmation_token', 'recovery_token',
    'email_change', 'email_change_token_new', 'email_change_token_current',
    'phone_change', 'phone_change_token', 'reauthentication_token'
  ] loop
    if exists (select 1 from information_schema.columns
                where table_schema = 'auth' and table_name = 'users'
                  and column_name = v_col) then

      execute format('update auth.users set %I = %L where %I is null',
                     v_col, '', v_col);
      get diagnostics v_n = row_count;
      v_tot := v_tot + v_n;

      if v_n > 0 then
        raise notice '% : % linha(s) reparada(s)', v_col, v_n;
      end if;
    end if;
  end loop;

  if v_tot = 0 then
    raise notice 'Nada a reparar: nenhuma coluna estava nula.';
  else
    raise notice 'Total de % atualizacao(oes). Os logins voltam na hora.', v_tot;
  end if;
end
$reparo$;

-- ------------------------------------------------------------
-- 2. A função para de criar o defeito
--
-- Mesmo corpo da 0044, com uma diferença: o insert em auth.users
-- agora preenche as oito colunas de texto com vazio, em vez de
-- deixá-las nulas.
-- ------------------------------------------------------------
create or replace function public.admin_criar_conta(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_admin  uuid := public.exigir_gestao();
  v_quem   text;
  v_alvo   text;
  v_nome   text := nullif(trim(p_dados->>'nome'), '');
  v_email  text := lower(nullif(trim(p_dados->>'email'), ''));
  v_org    text := nullif(trim(p_dados->>'organizacao'), '');
  v_papel  text := coalesce(nullif(trim(p_dados->>'papel'), ''), 'avaliador');
  v_id     uuid;
  v_novo   boolean := false;
begin
  select papel into v_quem from public.avaliadores where id = v_admin;

  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;
  if v_email is null
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;
  if v_papel not in ('avaliador', 'gestor', 'diretoria', 'supervisor', 'atendente', 'palestras') then
    raise exception 'papel_invalido';
  end if;

  -- (a) teto de papel
  if v_quem is distinct from 'diretoria' and v_papel <> 'avaliador' then
    raise exception 'papel_acima_do_seu';
  end if;

  select id into v_id from auth.users where lower(email) = v_email;

  if v_id is not null and v_quem is distinct from 'diretoria' then
    -- (c) não mexe na própria linha
    if v_id = v_admin then
      raise exception 'nao_altera_a_si';
    end if;
    -- (b) não escreve por cima de conta de outro nível
    select papel into v_alvo from public.avaliadores where id = v_id;
    if v_alvo is not null and v_alvo <> 'avaliador' then
      raise exception 'conta_protegida';
    end if;
  end if;

  if v_id is null then
    v_id := gen_random_uuid();
    v_novo := true;

    insert into auth.users (
      id, instance_id, aud, role, email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      -- Vazio, NUNCA nulo. O GoTrue lê estas colunas como texto e
      -- estoura "Database error finding user" ao encontrar null —
      -- a pessoa fica sem conseguir entrar, e a listagem de
      -- usuários do painel para junto.
      confirmation_token, recovery_token,
      email_change, email_change_token_new, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token
    ) values (
      v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', v_email,
      null,
      now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('nome', v_nome),
      now(), now(),
      '', '', '', '', '', '', '', ''
    );
  end if;

  insert into public.avaliadores (id, nome, email, organizacao, papel)
  values (v_id, v_nome, v_email, v_org, v_papel)
  on conflict (id) do update
    set nome = excluded.nome,
        email = excluded.email,
        organizacao = excluded.organizacao,
        papel = excluded.papel;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'nome', v_nome, 'email', v_email,
    'papel', v_papel, 'novo', v_novo);
end;
$$;

-- ------------------------------------------------------------
-- 3. Conferência depois de rodar
--
--   select count(*) as ainda_quebradas from auth.users
--    where confirmation_token is null or recovery_token is null
--       or email_change is null or email_change_token_new is null;
--   -- tem de dar 0
-- ------------------------------------------------------------
