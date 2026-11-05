-- ------------------------------------------------------------
-- Termo de ciência e autorização
--
-- O formulário passou a exibir um termo com finalidade, retenção,
-- canal de revogação e controlador, e a pedir duas coisas do
-- responsável: marcar que tem ciência e digitar o próprio nome
-- como confirmação.
--
-- Sem esta migration os dois campos chegam no p_dados e são
-- descartados: inscrever_aluno só grava as colunas que nomeia.
-- O termo apareceria na tela e não deixaria registro nenhum —
-- que é o pior dos dois mundos, porque a família acredita ter
-- assinado algo.
--
-- RODE ESTA MIGRATION ANTES DE PUBLICAR O FORMULÁRIO NOVO.
-- ------------------------------------------------------------

alter table public.alunos
  add column if not exists ciencia_compartilhamento boolean not null default false,
  add column if not exists assinatura_responsavel   text;

comment on column public.alunos.ciencia_compartilhamento is
  'Responsável marcou a caixa de ciência do termo. Diferente de '
  'consentimento_responsavel: aquele registra a decisão de '
  'compartilhar, este registra que leu o termo e se declarou '
  'responsável legal.';

comment on column public.alunos.assinatura_responsavel is
  'Nome completo digitado pelo responsável no fim do termo. É o '
  'ato de assinar — por isso é pedido de novo, mesmo já existindo '
  'responsavel_nome como dado cadastral. Divergência entre os '
  'dois não invalida nada, mas é sinal de que vale conferir.';

-- ------------------------------------------------------------
-- Versão do termo
--
-- O comentário da 0006 é explícito: mudar sempre que o TEXTO do
-- termo mudar, porque consentimento sem versionamento do texto
-- tem valor fraco. O texto mudou — passou a existir.
--
-- Quem se inscreveu antes fica com 'v1-2026' e continua válido
-- para o termo que viu na época. Não se reescreve consentimento
-- passado.
-- ------------------------------------------------------------
create or replace function public.versao_consentimento()
returns text
language sql
immutable
as $$
  select 'v2-2026'::text;
$$;

-- ------------------------------------------------------------
-- inscrever_aluno: passa a exigir e gravar a ciência
--
-- Recriada por inteiro porque create or replace não aceita
-- alteração parcial. Igual à da 0007, com três diferenças:
-- a validação da ciência, a da assinatura e as duas colunas
-- novas no insert.
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
begin
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

  if (select count(*) from alunos where lower(responsavel_email) = v_resp_email) >= 10 then
    raise exception 'limite_de_inscricoes';
  end if;

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

  return jsonb_build_object(
    'ok', true,
    'protocolo', upper(substr(replace(v_id::text, '-', ''), 1, 8))
  );
end;
$$;

-- A 0006 revoga de public e concede a anon/authenticated. O
-- create or replace acima preserva os grants existentes, mas
-- repetir não custa e protege contra a função ter sido dropada.
revoke execute on function public.versao_consentimento() from public;
revoke execute on function public.inscrever_aluno(jsonb)  from public;
grant  execute on function public.inscrever_aluno(jsonb)  to anon, authenticated;

-- ------------------------------------------------------------
-- Conferir depois de rodar:
--
--   select column_name, data_type, column_default
--     from information_schema.columns
--    where table_name = 'alunos'
--      and column_name in ('ciencia_compartilhamento',
--                          'assinatura_responsavel');
--
--   select public.versao_consentimento();   -- v2-2026
--
-- E uma inscrição de teste sem a ciência, que tem que falhar
-- com 'ciencia_obrigatoria'.
-- ------------------------------------------------------------
