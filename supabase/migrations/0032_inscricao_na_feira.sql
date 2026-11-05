-- ============================================================
-- 0032 — Inscrição feita pela própria pessoa, no dia
--
-- Quem chega sem inscrição hoje é cadastrado à mão pela mesa
-- (0025): a pessoa dita o nome, alguém digita, e a fila para. Com
-- 700 credenciados esperados, cada cadastro desses custa dois
-- minutos do balcão inteiro.
--
-- A alternativa é virar o trabalho: um cartaz com QR no local, a
-- pessoa escaneia com o próprio celular, preenche e envia. Ela
-- entra JÁ APROVADA, aparece na lista de presença, e o balcão só
-- confere, marca presença e imprime a folha com o QR dela.
--
-- POR QUE ENTRA APROVADA, SE O FORMULÁRIO DO SITE NÃO ENTRA
--
-- A revisão existe (0006) porque o formulário do site é público
-- na internet: qualquer um manda, de qualquer lugar, e a lista
-- que vira crachá impresso não pode aceitar isso sem conferência.
--
-- Aqui a conferência é física. Para chegar neste formulário é
-- preciso estar diante do cartaz, no salão do evento. E o crachá
-- não é impresso em gráfica dias antes: é uma folha impressa na
-- hora, com a pessoa na frente da mesa.
--
-- A CHAVE DENTRO DO QR
--
-- "Estar diante do cartaz" precisa virar algo que o banco possa
-- verificar. O QR carrega uma chave secreta, guardada em
-- `segredos`, e a função recusa envio sem ela. Quem descobrir a
-- URL sem o cartaz não passa.
--
-- Não é segredo forte — está numa URL que o celular de qualquer
-- inscrito enxerga — e não precisa ser. Ele existe para que o
-- endereço não circule sozinho, não para resistir a ataque. O
-- freio por IP da 0013 continua valendo por cima.
-- ============================================================

-- ------------------------------------------------------------
-- De onde veio cada inscrição
--
-- 'online'  — formulário do site, passou por revisão
-- 'feira'   — a pessoa se inscreveu no local, pelo QR
-- 'balcao'  — alguém da organização digitou por ela (0025)
--
-- Serve ao relatório depois do evento ("quantos apareceram sem
-- inscrição?") e, no dia, para a lista mostrar de onde a pessoa
-- veio. O que a mesa precisa saber mesmo é se há crachá impresso,
-- e isso continua sendo `cracha_lote is null`.
-- ------------------------------------------------------------
alter table public.alunos
  add column if not exists origem text not null default 'online';

comment on column public.alunos.origem is
  'online = formulário do site | feira = QR no local | balcao = digitado pela organização.';

insert into public.segredos (chave, valor)
values ('chave_feira', replace(gen_random_uuid()::text, '-', ''))
on conflict (chave) do nothing;

-- ------------------------------------------------------------
-- chave_feira(): o gestor lê a chave para montar o QR do cartaz
-- ------------------------------------------------------------
create or replace function public.chave_feira()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor uuid := public.exigir_gestor();
begin
  return (select valor from segredos where chave = 'chave_feira');
end;
$$;

revoke execute on function public.chave_feira() from public, anon;
grant  execute on function public.chave_feira() to authenticated;

-- ------------------------------------------------------------
-- inscrever_na_feira(dados)
--
-- Pública como a do site — quem preenche não tem login. O que
-- separa uma da outra é a chave.
-- ------------------------------------------------------------
create or replace function public.inscrever_na_feira(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_chave       text := nullif(trim(p_dados->>'chave'), '');
  v_tipo        text := coalesce(nullif(trim(p_dados->>'tipo'), ''), 'aluno');
  v_nome        text := nullif(trim(p_dados->>'nome'), '');
  v_onde        text := nullif(trim(p_dados->>'onde'), '');
  v_ano         text := nullif(trim(p_dados->>'ano'), '');
  v_email       text := lower(nullif(trim(p_dados->>'email'), ''));
  v_tel         text := nullif(trim(p_dados->>'telefone'), '');
  v_resp_nome   text := nullif(trim(p_dados->>'responsavel_nome'), '');
  v_da_rede     boolean := coalesce((p_dados->>'da_rede')::boolean, true);
  v_id          uuid;
  v_acomp       jsonb;
  v_acomp_nome  text;
  v_cabecalhos  jsonb;
  v_ip          text;
  v_ip_hash     text;
begin
  -- ---- a chave do cartaz ----
  if v_chave is null
     or v_chave <> (select valor from segredos where chave = 'chave_feira') then
    raise exception 'chave_invalida';
  end if;

  -- ---- freio de inundação (0013) ----
  v_cabecalhos := nullif(current_setting('request.headers', true), '')::jsonb;

  if v_cabecalhos is not null then
    v_ip := nullif(trim(coalesce(
      v_cabecalhos->>'cf-connecting-ip',
      split_part(v_cabecalhos->>'x-forwarded-for', ',', 1)
    )), '');
  end if;

  if v_ip is not null then
    v_ip_hash := encode(
      sha256((v_ip || (select valor from segredos where chave = 'sal_ip'))::bytea),
      'hex');

    /* Teto mais baixo que o do site (12): aqui uma pessoa preenche
       uma vez, pelo próprio celular. Mais de 6 envios da mesma
       origem em 10 minutos é a família inteira no mesmo Wi-Fi ou
       alguém brincando — e o balcão continua atrás, para o caso
       legítimo. */
    if (select count(*) from inscricao_tentativas
         where ip_hash = v_ip_hash
           and em > now() - interval '10 minutes') >= 6 then
      raise exception 'muitas_tentativas';
    end if;
  end if;

  if v_tipo not in ('aluno', 'counselor', 'docente') then
    raise exception 'tipo_invalido';
  end if;
  if v_nome is null or array_length(string_to_array(v_nome, ' '), 1) < 2 then
    raise exception 'nome_incompleto';
  end if;
  if v_email is not null
     and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;

  insert into alunos (
    tipo, nome, ano_escolaridade, aluno_alfacem,
    unidade, colegio,
    email, telefone, responsavel_nome,
    nivel_compartilhamento,
    consentimento_responsavel, consentimento_versao, consentimento_em,
    ciencia_compartilhamento,
    origem,
    -- Aprovada e NÃO presente: a pessoa pode preencher na fila,
    -- no estacionamento, na véspera à noite. Presença é o balcão
    -- que marca, olhando para ela.
    ativo, presente,
    -- Fora da fila de e-mail: ela está no evento, e "inscrição
    -- confirmada" no meio do salão é ruído.
    email_confirmacao_em
  ) values (
    v_tipo, v_nome, v_ano, v_da_rede,
    case when v_da_rede then v_onde else null end,
    case when v_da_rede then null else v_onde end,
    v_email, v_tel, v_resp_nome,
    3::smallint,
    true, 'feira-' || public.versao_consentimento(), now(),
    true,
    'feira',
    true, false,
    now()
  )
  returning id into v_id;

  for v_acomp in
    select * from jsonb_array_elements(coalesce(p_dados->'acompanhantes', '[]'::jsonb))
  loop
    v_acomp_nome := nullif(trim(v_acomp->>'nome'), '');
    continue when v_acomp_nome is null;

    insert into acompanhantes (aluno_id, nome, parentesco)
    values (v_id, v_acomp_nome, nullif(trim(v_acomp->>'parentesco'), ''));
  end loop;

  insert into inscricao_tentativas (ip_hash)
  values (coalesce(v_ip_hash, 'sem-origem'));

  delete from inscricao_tentativas where em < now() - interval '2 hours';

  return jsonb_build_object(
    'ok', true,
    'nome', v_nome,
    'codigo', (select codigo_curto from alunos where id = v_id)
  );
end;
$$;

revoke execute on function public.inscrever_na_feira(jsonb) from public;
grant  execute on function public.inscrever_na_feira(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- A lista do dia passa a dizer quem NÃO tem crachá impresso
--
-- É a informação que muda a ação da mesa: sem crachá, ela precisa
-- clicar em Imprimir antes de liberar a pessoa. Vale para quem se
-- inscreveu pelo QR, para quem foi digitado no balcão e para quem
-- foi aprovado depois da última leva.
-- ------------------------------------------------------------
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
                   'acompanhantes', (select count(*) from acompanhantes c
                                      where c.aluno_id = a.id),
                   'sem_cracha', a.cracha_lote is null,
                   'origem',   a.origem,
                   'ordem',    public.chave_nome(a.nome)
                 ) as linha
            from alunos a
           where a.ativo

          union all

          select jsonb_build_object(
                   'id',       c.id,
                   'kind',     'acompanhante',
                   'tipo',     'acompanhante',
                   'de',       a.id,
                   'nome',     c.nome,
                   'parentesco', c.parentesco,
                   'detalhe',  concat_ws(' · ',
                                 nullif(c.parentesco, ''),
                                 'acompanha ' || a.nome),
                   'codigo',   a.codigo_curto,
                   'presente', c.presente,
                   'sem_cracha', a.cracha_lote is null,
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
-- DEPOIS DO EVENTO
--
-- Quantos se inscreveram no próprio dia, e por qual caminho:
--
--   select origem, count(*) from public.alunos
--    where ativo group by origem order by 2 desc;
--
-- SE A CHAVE VAZAR (alguém publicou a foto do cartaz):
--
--   update public.segredos
--      set valor = replace(gen_random_uuid()::text, '-', '')
--    where chave = 'chave_feira';
--
-- O cartaz antigo para de funcionar na hora. Gere o QR de novo
-- pela tela de credenciamento e reimprima.
-- ------------------------------------------------------------
