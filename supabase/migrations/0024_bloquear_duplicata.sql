-- ============================================================
-- 0024 — Inscrição repetida é barrada no envio
--
-- Família que preenche duas vezes por achar que não enviou é o
-- erro mais comum do formulário, e vira dois crachás para a mesma
-- pessoa. Até agora isso só era pego na revisão, à mão.
--
-- POR QUE AQUI, E NÃO NUMA CONSULTA NA TELA
--
-- A ideia natural é um botão "verificar se já me inscrevi". Só
-- que uma função pública que responde "este e-mail já está
-- inscrito?" é uma máquina de enumeração: com a chave anon, que
-- está no código-fonte da página, qualquer um descobre quem vai
-- ao evento testando endereços. São menores de idade.
--
-- Barrar no momento do envio resolve o mesmo problema sem abrir
-- essa porta. Quem recebe a mensagem já sabe o próprio e-mail e o
-- nome do próprio filho — nada é revelado.
--
-- O CRITÉRIO
--
-- Aluno: mesmo nome E mesmo e-mail de responsável. Os dois
-- juntos, porque só o nome derrubaria dois "João Silva" de
-- famílias diferentes, e só o e-mail impediria a mãe de inscrever
-- o segundo filho — que é uso legítimo e comum.
--
-- Counselor e docente: mesmo e-mail e mesmo tipo. Uma pessoa não
-- se inscreve duas vezes como ela mesma. Isso substitui o limite
-- de 3 que existia desde a 0014, que era arbitrário.
-- ============================================================

-- ------------------------------------------------------------
-- chave_nome(): o nome reduzido ao que não varia
--
-- A mesma pessoa é digitada de formas diferentes entre um envio
-- e outro: "Ana Beatriz Silva" e "Ana Silva", "JOÃO" e "joao",
-- espaço a mais, acento a menos. Comparar o texto cru deixa
-- duplicata passar.
--
-- Esta função reduz o nome a PRIMEIRO + ÚLTIMO, sem acento e sem
-- caixa. "Ana Beatriz Silva" e "Ana Silva" viram os dois
-- "ana silva".
--
-- translate() e não unaccent(): o unaccent vive no schema
-- `extensions` no Supabase, e as funções aqui fixam
-- search_path = public, pg_temp. Seria "function does not exist"
-- na primeira inscrição real.
-- ------------------------------------------------------------
create or replace function public.chave_nome(p_nome text)
returns text
language sql
immutable
as $$
  select case
    when coalesce(trim(p_nome), '') = '' then null
    else (
      select lower(partes[1] || case when array_length(partes, 1) > 1
                                     then ' ' || partes[array_length(partes, 1)]
                                     else '' end)
        from (
          select string_to_array(
                   trim(regexp_replace(
                     translate(p_nome,
                       'áàâãäéèêëíìîïóòôõöúùûüñçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÑÇ',
                       'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC'),
                     '\s+', ' ', 'g')),
                   ' ') as partes
        ) q
    )
  end;
$$;

comment on function public.chave_nome(text) is
  'Nome reduzido a primeiro + último, sem acento nem caixa. '
  'Usado só para detectar inscrição repetida — nunca para exibir.';

create index if not exists alunos_chave_nome_idx
  on public.alunos (public.chave_nome(nome));

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
  v_assinatura  text := nullif(trim(p_dados->>'assinatura_responsavel'), '');
  v_paises      text[];
  v_id          uuid;
  v_acomp       jsonb;
  v_acomp_nome  text;
  v_cabecalhos  jsonb;
  v_ip          text;
  v_ip_hash     text;
begin
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

    if (select count(*) from inscricao_tentativas
         where ip_hash = v_ip_hash
           and em > now() - interval '10 minutes') >= 12 then
      raise exception 'muitas_tentativas';
    end if;
  end if;

  if (select count(*) from inscricao_tentativas
       where em > now() - interval '10 minutes') >= 300 then
    raise exception 'muitas_tentativas';
  end if;

  -- ---- validações ----

  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;
  if v_resp_nome is null or v_resp_email is null then
    raise exception 'responsavel_obrigatorio';
  end if;
  if v_resp_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;

  if coalesce((p_dados->>'consentimento_responsavel')::boolean, false) is not true then
    raise exception 'consentimento_obrigatorio';
  end if;

  if coalesce((p_dados->>'ciencia_compartilhamento')::boolean, false) is not true then
    raise exception 'ciencia_obrigatoria';
  end if;

  if v_assinatura is null or array_length(string_to_array(v_assinatura, ' '), 1) < 2 then
    raise exception 'assinatura_obrigatoria';
  end if;

  -- Mesmo aluno, mesmo contato: é a mesma inscrição de novo.
  --
  -- O nome sempre entra na comparação, e é o que protege o
  -- segundo filho: irmãos dividem e-mail e telefone, mas não
  -- nome. Sem ele, a mãe não conseguiria inscrever o caçula.
  --
  -- O contato bate por e-mail OU por telefone, porque quem
  -- reenvia por achar que falhou às vezes digita o e-mail
  -- diferente na segunda vez — e o telefone pega esse caso.
  --
  -- Ambos normalizados: nome sem espaço repetido nem caixa,
  -- telefone só com dígitos. É assim que a mesma informação
  -- chega diferente entre um envio e outro.
  if exists (
    select 1 from alunos
     where tipo = 'aluno'
       and public.chave_nome(nome) = public.chave_nome(v_nome)
       and (
         lower(responsavel_email) = v_resp_email
         or (
           nullif(regexp_replace(coalesce(responsavel_telefone, ''), '\D', '', 'g'), '')
           = nullif(regexp_replace(coalesce(p_dados->>'responsavel_telefone', ''), '\D', '', 'g'), '')
         )
       )
  ) then
    raise exception 'inscricao_duplicada';
  end if;

  -- Continua valendo como teto por responsável: irmãos, sim;
  -- lista de turma, não.
  if (select count(*) from alunos
       where tipo = 'aluno' and lower(responsavel_email) = v_resp_email) >= 10 then
    raise exception 'limite_de_inscricoes';
  end if;

  if jsonb_array_length(coalesce(p_dados->'acompanhantes', '[]'::jsonb)) > 3 then
    raise exception 'limite_de_acompanhantes';
  end if;

  insert into inscricao_tentativas (ip_hash)
  values (coalesce(v_ip_hash, 'sem-origem'));

  delete from inscricao_tentativas where em < now() - interval '2 hours';

  select coalesce(array_agg(valor), '{}')
    into v_paises
    from jsonb_array_elements_text(coalesce(p_dados->'paises_interesse', '[]'::jsonb)) as valor;

  insert into alunos (
    nome, email,
    aluno_alfacem, colegio, unidade, segmento, ano_escolaridade,
    responsavel_acompanha, parentesco,
    paises_interesse, motivo, experiencia_internacional, conhece_pathway,
    nivel_compartilhamento,
    consentimento_responsavel, consentimento_versao, consentimento_em,
    ciencia_compartilhamento, assinatura_responsavel,
    responsavel_nome, responsavel_email, responsavel_telefone,
    compartilhar_responsavel,
    ativo
  ) values (
    v_nome,
    lower(nullif(trim(p_dados->>'email'), '')),
    (p_dados->>'aluno_alfacem')::boolean,
    nullif(trim(p_dados->>'colegio'), ''),
    nullif(trim(p_dados->>'unidade'), ''),
    nullif(trim(p_dados->>'segmento'), ''),
    nullif(trim(p_dados->>'ano_escolaridade'), ''),
    nullif(trim(p_dados->>'responsavel_acompanha'), ''),
    nullif(trim(p_dados->>'parentesco'), ''),
    v_paises,
    nullif(trim(p_dados->>'motivo'), ''),
    nullif(trim(p_dados->>'experiencia_internacional'), ''),
    nullif(trim(p_dados->>'conhece_pathway'), ''),
    case when coalesce((p_dados->>'compartilhar_aluno')::boolean, false)
         then 3::smallint else 0::smallint end,
    true,
    public.versao_consentimento(),
    now(),
    true,
    v_assinatura,
    v_resp_nome,
    v_resp_email,
    nullif(trim(p_dados->>'responsavel_telefone'), ''),
    coalesce((p_dados->>'compartilhar_responsavel')::boolean, false),
    false
  )
  returning id into v_id;

  for v_acomp in
    select * from jsonb_array_elements(coalesce(p_dados->'acompanhantes', '[]'::jsonb))
  loop
    v_acomp_nome := nullif(trim(v_acomp->>'nome'), '');
    continue when v_acomp_nome is null;

    insert into acompanhantes (aluno_id, nome, parentesco, email, telefone)
    values (
      v_id, v_acomp_nome,
      nullif(trim(v_acomp->>'parentesco'), ''),
      lower(nullif(trim(v_acomp->>'email'), '')),
      nullif(trim(v_acomp->>'telefone'), '')
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'protocolo', upper(substr(replace(v_id::text, '-', ''), 1, 8))
  );
end;
$$;

-- ------------------------------------------------------------
-- Counselor e docente: um por e-mail, por tipo
-- ------------------------------------------------------------
create or replace function public.inscrever_counselor(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tipo        text := coalesce(nullif(trim(p_dados->>'tipo'), ''), 'counselor');
  v_nome        text := nullif(trim(p_dados->>'nome'), '');
  v_email       text := lower(nullif(trim(p_dados->>'email'), ''));
  v_telefone    text := nullif(trim(p_dados->>'telefone'), '');
  v_instituicao text := nullif(trim(p_dados->>'instituicao'), '');
  v_id          uuid;
  v_cabecalhos  jsonb;
  v_ip          text;
  v_ip_hash     text;
begin
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

    if (select count(*) from inscricao_tentativas
         where ip_hash = v_ip_hash
           and em > now() - interval '10 minutes') >= 12 then
      raise exception 'muitas_tentativas';
    end if;
  end if;

  if (select count(*) from inscricao_tentativas
       where em > now() - interval '10 minutes') >= 300 then
    raise exception 'muitas_tentativas';
  end if;

  if v_tipo not in ('counselor', 'docente') then
    raise exception 'tipo_invalido';
  end if;
  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;
  if v_email is null then
    raise exception 'email_obrigatorio';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;
  if v_instituicao is null then
    raise exception 'instituicao_obrigatoria';
  end if;

  if coalesce((p_dados->>'ciencia_compartilhamento')::boolean, false) is not true then
    raise exception 'ciencia_obrigatoria';
  end if;

  -- Uma pessoa não se inscreve duas vezes como ela mesma.
  if exists (select 1 from alunos where tipo = v_tipo and lower(email) = v_email) then
    raise exception 'inscricao_duplicada';
  end if;

  insert into inscricao_tentativas (ip_hash)
  values (coalesce(v_ip_hash, 'sem-origem'));

  delete from inscricao_tentativas where em < now() - interval '2 hours';

  insert into alunos (
    tipo, nome, email, telefone, colegio, unidade, aluno_alfacem,
    nivel_compartilhamento,
    consentimento_responsavel, consentimento_versao, consentimento_em,
    ciencia_compartilhamento,
    ativo
  ) values (
    v_tipo, v_nome, v_email, v_telefone,
    case when v_tipo = 'docente' then null else v_instituicao end,
    case when v_tipo = 'docente' then v_instituicao else null end,
    v_tipo = 'docente',
    3::smallint,
    true,
    public.versao_consentimento_counselor(),
    now(),
    true,
    false
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'protocolo', upper(substr(replace(v_id::text, '-', ''), 1, 8))
  );
end;
$$;

revoke execute on function public.inscrever_aluno(jsonb)      from public;
revoke execute on function public.inscrever_counselor(jsonb)  from public;
grant  execute on function public.inscrever_aluno(jsonb)      to anon, authenticated;
grant  execute on function public.inscrever_counselor(jsonb)  to anon, authenticated;

-- ------------------------------------------------------------
-- ANTES DE RODAR: as duplicatas que já existem continuam lá
--
-- Esta migration impede novas, não apaga antigas. Veja quais são:
--
--   select lower(regexp_replace(trim(nome), '\s+', ' ', 'g')) as nome,
--          count(*) as vezes,
--          string_agg(distinct coalesce(responsavel_email, email), ' · ') as contatos
--     from public.alunos
--    group by 1 having count(*) > 1
--    order by vezes desc;
--
-- Para apagar a mais antiga mantendo a última:
--
--   delete from public.alunos a
--    where exists (
--      select 1 from public.alunos b
--       where b.tipo = a.tipo
--         and lower(b.responsavel_email) = lower(a.responsavel_email)
--         and lower(trim(b.nome)) = lower(trim(a.nome))
--         and b.criado_em > a.criado_em);
--
-- O painel também lista as duplicatas, na seção de alertas.
-- ------------------------------------------------------------
