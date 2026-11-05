-- ============================================================
-- 0012 — Acompanhantes
--
-- Todo mundo que entra no evento precisa de crachá, não só o
-- aluno. Quem marca "acompanhado" no formulário passa a informar
-- quem vai junto, e cada acompanhante ganha o seu.
--
-- O QR DO ACOMPANHANTE É O DO PRÓPRIO ALUNO.
--
-- Essa é a decisão que mantém a migration pequena. O crachá do
-- acompanhante carrega o cracha_token do aluno que ele acompanha,
-- então escanear a mãe abre o perfil do filho — que é o
-- comportamento pedido. Como o token é o mesmo, nada muda em
-- buscar_aluno, salvar_contato, perfil_aluno, log_acesso nem no
-- app do avaliador. Acompanhante não tem token nem codigo_curto
-- próprios porque não tem perfil próprio para abrir.
--
-- O preço: o log_acesso não distingue "escanearam o crachá da
-- mãe" de "escanearam o crachá do filho". Os dois viram acesso ao
-- aluno, que é a informação que importa para a LGPD. Se um dia a
-- distinção fizer falta, aí sim cada crachá precisa de token
-- próprio — e isso é outra migration.
-- ============================================================

create table if not exists public.acompanhantes (
  id         uuid primary key default gen_random_uuid(),

  -- cascade: acompanhante é dado pessoal preso ao aluno. Pedido
  -- de exclusão feito pelo responsável apaga tudo num delete só,
  -- como manda a 0008.
  aluno_id   uuid not null references public.alunos(id) on delete cascade,

  nome       text not null,
  parentesco text,
  email      text,
  telefone   text,

  criado_em  timestamptz not null default now()
);

create index if not exists acompanhantes_aluno_id_idx
  on public.acompanhantes (aluno_id);

comment on table public.acompanhantes is
  'Adultos que acompanham o aluno no evento. Existem para gerar '
  'crachá de acesso. Não têm cracha_token: o QR do crachá deles é '
  'o token do aluno, e o app abre o perfil do aluno.';

comment on column public.acompanhantes.email is
  'Opcional. Não é mostrado a representante de universidade — o '
  'QR do acompanhante leva ao perfil do aluno, não ao dele. Serve '
  'à organização, para contato sobre o próprio evento.';

-- ------------------------------------------------------------
-- No máximo 3 acompanhantes por aluno
--
-- O limite existe no formulário, mas o formulário é HTML servido
-- ao navegador de qualquer um. A RPC é pública. Quem decide é o
-- banco.
--
-- Trigger e não check constraint: check não enxerga outras linhas
-- da própria tabela.
-- ------------------------------------------------------------
create or replace function public.limitar_acompanhantes()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.acompanhantes
       where aluno_id = new.aluno_id) >= 3 then
    raise exception 'limite_de_acompanhantes';
  end if;
  return new;
end;
$$;

drop trigger if exists acompanhantes_limite on public.acompanhantes;
create trigger acompanhantes_limite
  before insert on public.acompanhantes
  for each row execute function public.limitar_acompanhantes();

-- ------------------------------------------------------------
-- RLS: mesmo tratamento de `alunos`
--
-- Ativo e sem nenhuma policy. Ninguém lê direto, nem o avaliador
-- logado. O gerador de crachás lê com a service_role, que ignora
-- RLS por ser dono. O grant padrão do Supabase sai junto, pelo
-- mesmo motivo descrito na 0002: se alguém criar uma policy por
-- engano, o grant não estará de pé esperando.
-- ------------------------------------------------------------
alter table public.acompanhantes enable row level security;
revoke all on public.acompanhantes from anon, authenticated;

-- ------------------------------------------------------------
-- inscrever_aluno: passa a gravar os acompanhantes
--
-- Recriada por inteiro (create or replace não aceita alteração
-- parcial). Igual à da 0010, com o bloco de inserção no fim.
--
-- Grava depois do aluno porque precisa do id dele. Se algum
-- acompanhante estourar o limite ou vier sem nome, a exceção
-- desfaz a inscrição inteira — função em plpgsql é uma
-- transação. É o comportamento certo: melhor a família ver erro
-- e corrigir do que entrar sem os acompanhantes que informou.
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

  if jsonb_array_length(coalesce(p_dados->'acompanhantes', '[]'::jsonb)) > 3 then
    raise exception 'limite_de_acompanhantes';
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

revoke execute on function public.limitar_acompanhantes() from public, anon, authenticated;
revoke execute on function public.inscrever_aluno(jsonb)  from public;
grant  execute on function public.inscrever_aluno(jsonb)  to anon, authenticated;

-- ------------------------------------------------------------
-- Conferir depois de rodar:
--
--   -- tabela sem policy nenhuma, como alunos
--   select tablename, rowsecurity from pg_tables
--    where schemaname = 'public' and tablename = 'acompanhantes';
--   select count(*) from pg_policies
--    where schemaname = 'public' and tablename = 'acompanhantes';   -- 0
--
--   -- o limite de 3 barra o quarto
--   -- (rode num aluno de teste e confira que estoura
--   --  com 'limite_de_acompanhantes')
--
--   -- apagar o aluno leva os acompanhantes junto
--   select c.conname, c.confdeltype = 'c' as cascateia
--     from pg_constraint c join pg_class t on t.oid = c.conrelid
--    where c.contype = 'f' and t.relname = 'acompanhantes';
--
-- Fila de revisão, agora com os acompanhantes:
--
--   select a.nome, a.responsavel_nome,
--          coalesce(string_agg(c.nome || ' (' || coalesce(c.parentesco,'?') || ')', ', '), '—') as acompanhantes
--     from public.alunos a
--     left join public.acompanhantes c on c.aluno_id = a.id
--    where not a.ativo
--    group by a.id, a.nome, a.responsavel_nome
--    order by a.nome;
-- ------------------------------------------------------------
