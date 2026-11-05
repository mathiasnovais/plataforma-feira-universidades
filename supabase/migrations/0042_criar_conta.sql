-- ============================================================
-- 0042 — Criar e apagar conta de acesso pelo navegador
--
-- A 0041 deixou de fora a criação de login, com o argumento de
-- que exigiria a service_role no navegador. O argumento estava
-- errado pela metade: a chave realmente não pode ir para a
-- página, mas o BANCO pode fazer o trabalho.
--
-- Uma função `security definer` roda com o privilégio do dono e
-- alcança o schema `auth`. A tela chama a função com a sessão da
-- diretoria; a criação acontece dentro do servidor, e nenhuma
-- chave de administração sai de lá.
--
-- O QUE ISTO ESCREVE, E O RISCO QUE TEM
--
-- `auth.users` é uma tabela do Supabase, não deste projeto.
-- Escrever nela direto funciona e é prática comum, mas não é
-- interface oficial: uma mudança de schema num upgrade do
-- Supabase pode quebrar esta função. O sinal será claro — erro de
-- coluna inexistente na hora de criar uma conta — e o conserto é
-- ajustar a lista de colunas aqui.
--
-- A alternativa oficial é uma Edge Function guardando a
-- service_role. Ela não quebra em upgrade, mas exige publicar
-- código fora deste repositório, num lugar a mais para manter.
-- Para o volume deste projeto — algumas dezenas de contas — o
-- ganho não paga o custo.
--
-- POR QUE SÓ SENHA VAZIA
--
-- Ninguém neste sistema entra com senha: o login é e-mail mais
-- código de seis dígitos. A conta nasce com `encrypted_password`
-- nulo e o e-mail já confirmado, que é exatamente o que o fluxo
-- de OTP precisa encontrar.
-- ============================================================

create or replace function public.admin_criar_conta(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_admin  uuid := public.exigir_diretoria();
  v_nome   text := nullif(trim(p_dados->>'nome'), '');
  v_email  text := lower(nullif(trim(p_dados->>'email'), ''));
  v_org    text := nullif(trim(p_dados->>'organizacao'), '');
  v_papel  text := coalesce(nullif(trim(p_dados->>'papel'), ''), 'avaliador');
  v_id     uuid;
  v_novo   boolean := false;
begin
  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;
  if v_email is null
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;
  if v_papel not in ('avaliador', 'gestor', 'diretoria') then
    raise exception 'papel_invalido';
  end if;

  /* Já existe no auth? Então é alguém que já entrou algum dia, ou
     que teve o acesso revogado — reaproveita em vez de criar
     outro, senão o e-mail duplicaria e o login pararia de saber
     qual conta usar. */
  select id into v_id from auth.users where lower(email) = v_email;

  if v_id is null then
    v_id := gen_random_uuid();
    v_novo := true;

    insert into auth.users (
      id, instance_id, aud, role, email,
      encrypted_password,
      -- Confirmado na criação: o OTP é o que autentica, e um
      -- e-mail pendente de confirmação não recebe código.
      email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) values (
      v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', v_email,
      null,
      now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('nome', v_nome),
      now(), now()
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

revoke execute on function public.admin_criar_conta(jsonb) from public, anon;
grant  execute on function public.admin_criar_conta(jsonb) to authenticated;

-- ------------------------------------------------------------
-- admin_apagar_conta(id): apaga de vez
--
-- Diferente de admin_revogar (0041), que só tira o acesso e
-- mantém o usuário do auth. Aqui some tudo — inclusive os
-- contatos que a pessoa salvou, por cascade da 0008.
--
-- As duas existem porque servem a momentos diferentes: revogar é
-- para quem saiu da função e pode voltar; apagar é para cadastro
-- errado, feito agora e que não deveria existir.
-- ------------------------------------------------------------
create or replace function public.admin_apagar_conta(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_admin uuid := public.exigir_diretoria();
  v_nome  text;
  v_n     integer;
begin
  if p_id = v_admin then raise exception 'nao_apaga_a_si'; end if;

  select nome into v_nome from public.avaliadores where id = p_id;
  select count(*) into v_n from public.contatos_salvos where avaliador_id = p_id;

  delete from public.avaliadores where id = p_id;
  delete from auth.users where id = p_id;

  if v_nome is null then raise exception 'nao_encontrado'; end if;

  return jsonb_build_object('ok', true, 'nome', v_nome, 'contatos', v_n);
end;
$$;

revoke execute on function public.admin_apagar_conta(uuid) from public, anon;
grant  execute on function public.admin_apagar_conta(uuid) to authenticated;

-- ------------------------------------------------------------
-- DEPOIS DE CRIAR, O CÓDIGO PRECISA CHEGAR
--
-- O n8n recusa e-mail de domínio fora da lista, e a pessoa nova
-- ficaria pedindo código que nunca chega. Se o domínio for novo,
-- acrescente em DOMINIOS_PERMITIDOS no nó "Validar payload" do
-- workflow enviar-otp.
--
-- Conferir se uma conta ficou completa:
--
--   select a.nome, a.email, a.papel,
--          u.email_confirmed_at is not null as confirmado,
--          u.last_sign_in_at
--     from public.avaliadores a
--     join auth.users u on u.id = a.id
--    where a.email = 'quem@for.com';
-- ------------------------------------------------------------
