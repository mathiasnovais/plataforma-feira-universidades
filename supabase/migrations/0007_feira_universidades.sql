-- ============================================================
-- 0007 — Adequação à feira de universidades
--
-- O schema original (0001) foi escrito a partir de um documento
-- que descrevia feira de PROJETOS escolares: turma, projeto,
-- resumo. O formulário real é de feira de UNIVERSIDADES — os
-- avaliadores são representantes de instituições e o que eles
-- precisam ver é qualificação de candidato, não pitch de projeto.
--
-- Esta migration troca os campos pelos que o formulário coleta.
-- ============================================================

-- ------------------------------------------------------------
-- Contexto escolar
-- ------------------------------------------------------------
-- `if not exists` / `if exists` em toda a migration: o fluxo aqui
-- é colar no SQL Editor, e rodar duas vezes por engano acontece.
-- Sem isso, a segunda execução para no meio e deixa o schema
-- pela metade.
alter table public.alunos
  add column if not exists aluno_alfacem         boolean,  -- é aluno da rede?
  add column if not exists colegio               text,     -- se não for, qual
  add column if not exists unidade               text,     -- Barra Américas, Freguesia...
  add column if not exists segmento              text,     -- Ensino Médio, etc.
  add column if not exists ano_escolaridade      text,
  add column if not exists responsavel_acompanha text,     -- vem junto no evento?
  add column if not exists parentesco            text;     -- Mãe, Pai, Avó/Avô, Outro

-- ------------------------------------------------------------
-- Interesses — é o que o representante de universidade usa
--
-- paises_interesse é array: a pergunta é de múltipla escolha.
-- Guardar como texto separado por vírgula tornaria impossível
-- responder "quantos alunos querem Canadá" sem gambiarra.
-- ------------------------------------------------------------
alter table public.alunos
  add column if not exists paises_interesse          text[],
  add column if not exists motivo                    text,
  add column if not exists experiencia_internacional text,
  add column if not exists conhece_pathway           text;

create index if not exists alunos_paises_interesse_idx
  on public.alunos using gin (paises_interesse);

-- ------------------------------------------------------------
-- Fora o que não existe neste evento
--
-- Nenhuma dessas colunas é preenchida pelo formulário. Coluna
-- morta em tabela de dado pessoal é pior que inútil: alguém
-- eventualmente preenche e ninguém sabe quem pode ver.
-- ------------------------------------------------------------
alter table public.alunos
  drop column if exists turma,
  drop column if exists projeto,
  drop column if exists resumo,
  drop column if exists telefone,
  drop column if exists linkedin;

-- ------------------------------------------------------------
-- perfil_aluno — o que o representante vê ao escanear
--
-- DECISÃO DE ESCOPO, revise se discordar:
--
-- Os dados de interesse (segmento, ano, países, motivo,
-- experiência) são dados DO ALUNO, então seguem a autorização
-- DO ALUNO (consAluno no formulário). Se o aluno não autorizou
-- mas o responsável sim, o representante vê o nome e o contato
-- do responsável — e conversa com ele.
--
-- A alternativa seria liberar os interesses pela autorização do
-- responsável. Dá lead mais rico, mas mostra escolha de quem
-- disse que não queria compartilhar.
-- ------------------------------------------------------------
create or replace function public.perfil_aluno(a public.alunos, p_ja_salvo boolean)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'aluno_id',     a.id,
    'nome',         a.nome,
    'codigo_curto', a.codigo_curto,
    'nivel',        public.nivel_efetivo(a),

    -- contexto escolar
    'escola',       case when public.nivel_efetivo(a) >= 1
                         then coalesce(a.colegio,
                                       case when a.aluno_alfacem
                                            then 'Alfacem Global Academy' end) end,
    'unidade',      case when public.nivel_efetivo(a) >= 1 then a.unidade end,
    'segmento',     case when public.nivel_efetivo(a) >= 1 then a.segmento end,
    'ano',          case when public.nivel_efetivo(a) >= 1 then a.ano_escolaridade end,

    -- qualificação
    'paises',       case when public.nivel_efetivo(a) >= 1 then to_jsonb(a.paises_interesse) end,
    'motivo',       case when public.nivel_efetivo(a) >= 1 then a.motivo end,
    'experiencia',  case when public.nivel_efetivo(a) >= 1 then a.experiencia_internacional end,
    'pathway',      case when public.nivel_efetivo(a) >= 1 then a.conhece_pathway end,

    -- contato do aluno
    'email',        case when public.nivel_efetivo(a) >= 2 then a.email end,

    -- contato do responsável: autorização independente
    'parentesco',           case when public.responsavel_liberado(a) then a.parentesco           end,
    'responsavel_nome',     case when public.responsavel_liberado(a) then a.responsavel_nome     end,
    'responsavel_email',    case when public.responsavel_liberado(a) then a.responsavel_email    end,
    'responsavel_telefone', case when public.responsavel_liberado(a) then a.responsavel_telefone end,

    'pode_salvar',  public.pode_salvar(a),
    'ja_salvo',     p_ja_salvo
  );
$$;

-- ------------------------------------------------------------
-- inscrever_aluno — passa a receber os campos do formulário
--
-- As duas perguntas de autorização do formulário mapeiam assim:
--
--   consAluno = "Sim, autorizo"  ->  nivel_compartilhamento = 3
--   consAluno = "Não autorizo"   ->  nivel_compartilhamento = 0
--   consResp  = "Sim, autorizo"  ->  compartilhar_responsavel = true
--
-- Os níveis 1 e 2 continuam existindo no schema. Se um dia o
-- formulário ganhar granularidade, não precisa mexer no banco.
-- ------------------------------------------------------------
create or replace function public.inscrever_aluno(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nome       text := nullif(trim(p_dados->>'nome'), '');
  v_resp_nome  text := nullif(trim(p_dados->>'responsavel_nome'), '');
  v_resp_email text := lower(nullif(trim(p_dados->>'responsavel_email'), ''));
  v_paises     text[];
  v_id         uuid;
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
