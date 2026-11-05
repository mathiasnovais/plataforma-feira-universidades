-- ============================================================
-- 0013 — Freio contra inundação de inscrições, e higiene de grants
--
-- inscrever_aluno é escrita pública sem autenticação: qualquer um
-- que abra o código-fonte da página encontra a RPC e pode chamá-la
-- direto. A única defesa era o limite de 10 por e-mail de
-- responsável, que se contorna trocando o e-mail a cada envio.
--
-- O estrago não é vazamento — é a fila de revisão virar inútil na
-- véspera, quando ela é a coisa de que a organização mais precisa.
--
-- O QUE NÃO MUDA: o limite de 10 por e-mail. É ele que atende
-- família com mais de um filho, e 10 dá folga de sobra. Nenhum
-- freio novo conta por pessoa.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Índice que faltava
--
-- A checagem de 10 por e-mail faz `where lower(responsavel_email)
-- = ...` e não havia índice para isso: varredura completa da
-- tabela a cada inscrição. Com 600 linhas não se nota; é
-- justamente sob inundação que pesa, e aí o ataque acelera
-- sozinho — quanto mais lixo entra, mais lenta fica cada
-- inscrição legítima.
-- ------------------------------------------------------------
create index if not exists alunos_responsavel_email_idx
  on public.alunos (lower(responsavel_email));

-- ------------------------------------------------------------
-- 2. Segredo para derivar o hash de IP
--
-- Guardar IP em claro é guardar dado pessoal a mais, num projeto
-- que já carrega dado de menor de idade. O IP entra hasheado com
-- um segredo que só a função enxerga: serve para contar
-- repetição, não para identificar ninguém, e não há como voltar
-- ao IP original sem o segredo.
--
-- gen_random_uuid() gera o segredo aqui, uma vez. O `on conflict
-- do nothing` mantém a migration repetível sem trocar o segredo
-- de quem já rodou.
-- ------------------------------------------------------------
create table if not exists public.segredos (
  chave text primary key,
  valor text not null
);

alter table public.segredos enable row level security;
revoke all on public.segredos from anon, authenticated;

insert into public.segredos (chave, valor)
values ('sal_ip', gen_random_uuid()::text)
on conflict (chave) do nothing;

-- ------------------------------------------------------------
-- 3. Registro de tentativas
--
-- Só o hash e a hora. Sem ligação com o aluno inscrito: se
-- ligasse, viraria um rastro de "quem inscreveu de onde", que é
-- exatamente o dado que não queremos ter.
--
-- Linhas velhas são apagadas a cada inscrição, então a tabela
-- vive com o volume de duas horas — algumas dezenas de linhas no
-- uso normal.
-- ------------------------------------------------------------
create table if not exists public.inscricao_tentativas (
  id      bigserial primary key,
  ip_hash text        not null,
  em      timestamptz not null default now()
);

create index if not exists inscricao_tentativas_ip_idx
  on public.inscricao_tentativas (ip_hash, em desc);
create index if not exists inscricao_tentativas_em_idx
  on public.inscricao_tentativas (em);

alter table public.inscricao_tentativas enable row level security;
revoke all on public.inscricao_tentativas from anon, authenticated;

comment on table public.inscricao_tentativas is
  'Contagem de inscrições por origem, para o freio de inundação. '
  'Guarda hash de IP, nunca o IP. Não se liga ao aluno inscrito, '
  'de propósito: ligar criaria um rastro de quem inscreveu de onde.';

-- ------------------------------------------------------------
-- 4. Higiene de grants
--
-- Achado da auditoria: `anon` executava versao_consentimento e
-- tocar_atualizado_em. Nenhuma das duas vaza coisa alguma — a
-- primeira devolve a string da versão do termo, a segunda é
-- função de trigger e nem é chamável de fora. Mas o LEIAME.md diz
-- que anon não executa nada, e agora não executa.
--
-- A causa: `revoke ... from public` NÃO basta no Supabase, que
-- concede EXECUTE a anon e authenticated por padrão nas funções
-- do schema public. Tem que revogar dos dois nominalmente. As
-- migrations 0006 e 0010 revogaram só de `public`.
-- ------------------------------------------------------------
revoke execute on function public.versao_consentimento()  from public, anon, authenticated;
revoke execute on function public.tocar_atualizado_em()   from public, anon, authenticated;

-- ------------------------------------------------------------
-- 5. inscrever_aluno com o freio
--
-- Recriada por inteiro (create or replace não aceita alteração
-- parcial). Idêntica à da 0012, com o bloco de freio no começo.
--
-- OS NÚMEROS, e por que estes:
--
--   10 por e-mail de responsável (JÁ EXISTIA, não muda)
--       É o limite que atende irmãos. Família com 4 filhos usa 4.
--
--   12 por origem em 10 minutos
--       Uma família preenchendo para vários filhos, do mesmo
--       computador, faz 3 ou 4 — e leva minutos em cada um, com
--       cinco etapas para preencher. 12 é folga larga sobre o uso
--       real e freio apertado sobre script, que faria centenas.
--
--   300 no total em 10 minutos
--       Rede de segurança para o caso de virem de vários lugares.
--       São ~600 alunos no evento inteiro; 300 em dez minutos é
--       acima de qualquer pico legítimo possível.
--
-- Ambos são janela deslizante: passados os 10 minutos, libera
-- sozinho. Ninguém fica travado de forma permanente por engano.
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
  v_assinatura  text := nullif(trim(p_dados->>'assinatura_responsavel'), '');
  v_paises      text[];
  v_id          uuid;
  v_acomp       jsonb;
  v_acomp_nome  text;
  v_cabecalhos  jsonb;
  v_ip          text;
  v_ip_hash     text;
begin
  -- ---- freio de inundação ----
  --
  -- Vem antes de tudo: barrar cedo custa menos que validar um
  -- corpo inteiro para descartar depois.
  --
  -- O IP sai dos cabeçalhos que o PostgREST expõe. cf-connecting-ip
  -- é o do Cloudflare, que está na frente; x-forwarded-for é o
  -- caminho comum e pode vir com vários IPs separados por vírgula,
  -- dos quais o primeiro é o cliente.
  --
  -- Chamada sem cabeçalho (SQL Editor, service_role, teste) fica
  -- de fora do freio por origem em vez de cair num balde comum —
  -- senão a organização se autobloquearia testando.
  v_cabecalhos := nullif(current_setting('request.headers', true), '')::jsonb;

  if v_cabecalhos is not null then
    v_ip := coalesce(
      v_cabecalhos->>'cf-connecting-ip',
      split_part(v_cabecalhos->>'x-forwarded-for', ',', 1)
    );
    v_ip := nullif(trim(v_ip), '');
  end if;

  if v_ip is not null then
    -- sha256() nativo do Postgres, não o digest() do pgcrypto: a
    -- função fixa search_path = public, pg_temp, e no Supabase o
    -- pgcrypto mora no schema `extensions`. digest() aqui daria
    -- "function does not exist" na primeira inscrição real.
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
  if v_resp_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'email_invalido';
  end if;

  -- Consentimento do responsável é a base legal da inscrição
  -- inteira: o aluno é menor. Sem ele, não há inscrição.
  if coalesce((p_dados->>'consentimento_responsavel')::boolean, false) is not true then
    raise exception 'consentimento_obrigatorio';
  end if;

  -- A validação da tela pode ser burlada: a RPC é pública e
  -- aceita qualquer corpo. Se a ciência é obrigatória, quem
  -- decide isso é o banco.
  if coalesce((p_dados->>'ciencia_compartilhamento')::boolean, false) is not true then
    raise exception 'ciencia_obrigatoria';
  end if;

  -- Assinatura com pelo menos duas palavras: um primeiro nome
  -- sozinho não identifica quem assinou, que é a única função
  -- do campo.
  if v_assinatura is null or array_length(string_to_array(v_assinatura, ' '), 1) < 2 then
    raise exception 'assinatura_obrigatoria';
  end if;

  -- Irmãos: 10 é folga para qualquer família real.
  if (select count(*) from alunos where lower(responsavel_email) = v_resp_email) >= 10 then
    raise exception 'limite_de_inscricoes';
  end if;

  if jsonb_array_length(coalesce(p_dados->'acompanhantes', '[]'::jsonb)) > 3 then
    raise exception 'limite_de_acompanhantes';
  end if;

  -- Registrado só depois das validações: erro de digitação da
  -- família não consome cota.
  insert into inscricao_tentativas (ip_hash)
  values (coalesce(v_ip_hash, 'sem-origem'));

  delete from inscricao_tentativas where em < now() - interval '2 hours';

  -- jsonb array -> text[]; ausente vira array vazio, não null
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

    -- Sim/Não do formulário -> 3 ou 0
    case when coalesce((p_dados->>'compartilhar_aluno')::boolean, false)
         then 3::smallint else 0::smallint end,

    true,
    public.versao_consentimento(),
    now(),
    true,           -- já validado acima
    v_assinatura,
    v_resp_nome,
    v_resp_email,
    nullif(trim(p_dados->>'responsavel_telefone'), ''),
    coalesce((p_dados->>'compartilhar_responsavel')::boolean, false),
    false
  )
  returning id into v_id;

  -- Acompanhantes. Sem nome não há crachá para imprimir, então
  -- entrada vazia é descartada em silêncio em vez de virar erro:
  -- o formulário deixa o bloco em branco quando a família começa
  -- a preencher e desiste.
  for v_acomp in
    select * from jsonb_array_elements(coalesce(p_dados->'acompanhantes', '[]'::jsonb))
  loop
    v_acomp_nome := nullif(trim(v_acomp->>'nome'), '');
    continue when v_acomp_nome is null;

    insert into acompanhantes (aluno_id, nome, parentesco, email, telefone)
    values (
      v_id,
      v_acomp_nome,
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

revoke execute on function public.inscrever_aluno(jsonb) from public;
grant  execute on function public.inscrever_aluno(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- Conferir depois de rodar
--
--   -- anon agora executa SÓ inscrever_aluno e ping
--   select p.proname
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and has_function_privilege('anon', p.oid, 'execute')
--    order by 1;
--
--   -- as duas tabelas novas: RLS ativa, zero policy
--   select tablename, rowsecurity from pg_tables
--    where schemaname = 'public'
--      and tablename in ('segredos', 'inscricao_tentativas');
--
--   -- o índice entrou
--   select indexname from pg_indexes
--    where tablename = 'alunos' and indexname = 'alunos_responsavel_email_idx';
--
--   -- quanto do freio está sendo usado agora
--   select count(*) as ultimos_10_min
--     from public.inscricao_tentativas
--    where em > now() - interval '10 minutes';
--
-- SE UMA FAMÍLIA FOR BLOQUEADA POR ENGANO
--
-- A janela é deslizante: em 10 minutos libera sozinha. Para
-- liberar na hora, apague as tentativas recentes:
--
--   delete from public.inscricao_tentativas
--    where em > now() - interval '10 minutes';
--
-- Isso zera o contador de todo mundo, o que é aceitável: o freio
-- existe para conter script, não para punir família.
-- ------------------------------------------------------------
