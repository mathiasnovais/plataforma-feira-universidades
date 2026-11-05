-- ============================================================
-- 0019 — Docente da Rede como quarto tipo de inscrição
--
-- O evento não recebe só aluno. Já havia o College Counselor
-- externo; entra agora o docente da própria Rede, que vem
-- acompanhar os alunos e conversar com as universidades.
--
-- Docente e counselor percorrem o MESMO caminho: formulário curto
-- de uma etapa, sem aluno e sem acompanhante, crachá com QR
-- próprio. A diferença é de onde vêm — o counselor digita a
-- instituição, o docente escolhe entre as unidades da Rede.
--
-- Por isso não há função nova: inscrever_counselor passa a
-- aceitar qual dos dois é. Duplicar a função para trocar uma
-- string faria duas cópias saindo de sincronia na primeira
-- correção.
-- ============================================================

alter table public.alunos
  drop constraint if exists alunos_tipo_check;

alter table public.alunos
  add constraint alunos_tipo_check
    check (tipo in ('aluno', 'counselor', 'docente'));

comment on column public.alunos.tipo is
  'aluno = inscrição normal, com responsável e acompanhantes. '
  'counselor = College Counselor de outro colégio. '
  'docente = professor ou coordenador da própria Rede. '
  'Os dois últimos se inscrevem sozinhos, sem acompanhante. '
  'Quem quiser contar só alunos precisa filtrar por esta coluna.';

-- ------------------------------------------------------------
-- inscrever_counselor: passa a aceitar o tipo
--
-- Recriada por inteiro (create or replace não aceita alteração
-- parcial). Igual à da 0014, com o tipo vindo do p_dados e
-- validado contra a mesma lista do check da tabela — a RPC é
-- pública, então quem decide o que é aceitável é aqui, não a
-- tela.
--
-- O nome da função fica: renomear obrigaria a mexer no formulário
-- publicado e nos grants, e o ganho seria cosmético.
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
  -- ---- freio de inundação (igual ao da 0013) ----
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

  -- 'aluno' não entra por aqui: aquele fluxo tem consentimento de
  -- menor, assinatura e acompanhantes, e é o inscrever_aluno.
  if v_tipo not in ('counselor', 'docente') then
    raise exception 'tipo_invalido';
  end if;

  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;
  if v_email is null then
    raise exception 'email_obrigatorio';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'email_invalido';
  end if;
  if v_instituicao is null then
    raise exception 'instituicao_obrigatoria';
  end if;

  if coalesce((p_dados->>'ciencia_compartilhamento')::boolean, false) is not true then
    raise exception 'ciencia_obrigatoria';
  end if;

  if (select count(*) from alunos
       where tipo = v_tipo and lower(email) = v_email) >= 3 then
    raise exception 'limite_de_inscricoes';
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
    -- Docente é da Rede: a origem dele é uma unidade, e vai na
    -- coluna `unidade`, a mesma que os alunos usam — assim o
    -- painel agrupa docente e aluno da mesma unidade juntos.
    case when v_tipo = 'docente' then null else v_instituicao end,
    case when v_tipo = 'docente' then v_instituicao else null end,
    v_tipo = 'docente',
    3::smallint,
    true,
    public.versao_consentimento_counselor(),
    now(),
    true,
    false          -- aguarda revisão, como toda inscrição
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'protocolo', upper(substr(replace(v_id::text, '-', ''), 1, 8))
  );
end;
$$;

revoke execute on function public.inscrever_counselor(jsonb) from public;
grant  execute on function public.inscrever_counselor(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- perfil_aluno: a instituição do docente vem da unidade
--
-- Recriada da 0014 com uma linha diferente: 'instituicao' passa a
-- cair na unidade quando não há colégio. Sem isso, o crachá do
-- docente abriria no app sem dizer de onde ele é.
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
    'tipo',         a.tipo,

    'escola',       case when public.nivel_efetivo(a) >= 1
                         then coalesce(a.colegio,
                                       case when a.aluno_alfacem
                                            then 'Rede Alfacem Global Academy' end) end,
    'instituicao',  case when public.nivel_efetivo(a) >= 1
                         then coalesce(a.colegio, a.unidade) end,
    'unidade',      case when public.nivel_efetivo(a) >= 1 then a.unidade end,
    'segmento',     case when public.nivel_efetivo(a) >= 1 then a.segmento end,
    'ano',          case when public.nivel_efetivo(a) >= 1 then a.ano_escolaridade end,

    'paises',       case when public.nivel_efetivo(a) >= 1 then to_jsonb(a.paises_interesse) end,
    'motivo',       case when public.nivel_efetivo(a) >= 1 then a.motivo end,
    'experiencia',  case when public.nivel_efetivo(a) >= 1 then a.experiencia_internacional end,
    'pathway',      case when public.nivel_efetivo(a) >= 1 then a.conhece_pathway end,

    'email',        case when public.nivel_efetivo(a) >= 2 then a.email end,
    'telefone',     case when public.nivel_efetivo(a) >= 2 then a.telefone end,

    'parentesco',           case when public.responsavel_liberado(a) then a.parentesco           end,
    'responsavel_nome',     case when public.responsavel_liberado(a) then a.responsavel_nome     end,
    'responsavel_email',    case when public.responsavel_liberado(a) then a.responsavel_email    end,
    'responsavel_telefone', case when public.responsavel_liberado(a) then a.responsavel_telefone end,

    'pode_salvar',  public.pode_salvar(a),
    'ja_salvo',     p_ja_salvo
  );
$$;

-- ------------------------------------------------------------
-- Conferir depois de rodar
--
--   select tipo, count(*) from public.alunos group by tipo;
--
--   -- o check aceita os três e recusa o resto
--   select conname, pg_get_constraintdef(oid)
--     from pg_constraint where conname = 'alunos_tipo_check';
--
-- ATENÇÃO: as consultas do painel que separam "aluno" de
-- "counselor" agora precisam considerar o docente. A
-- painel_publico() usa `tipo <> 'counselor'`, o que jogaria o
-- docente no meio dos alunos — corrigido na 0020.
-- ------------------------------------------------------------
