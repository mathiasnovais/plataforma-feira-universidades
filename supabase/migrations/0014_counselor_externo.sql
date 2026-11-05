-- ============================================================
-- 0014 — College Counselor externo
--
-- Terceira via de inscrição: profissional de orientação de outro
-- colégio, que vem à feira sem aluno e sem acompanhante. Recebe
-- crachá com QR próprio, e o representante que escanear vê o
-- contato dele e pode salvar — counselor é fonte de indicação, é
-- exatamente quem a universidade quer conhecer.
--
-- POR QUE ELE ENTRA NA TABELA `alunos`
--
-- A alternativa era tabela própria. Ela obrigaria a mexer em
-- buscar_aluno, salvar_contato, listar_meus_contatos,
-- contatos_salvos e log_acesso — as cinco peças do caminho que o
-- avaliador percorre no dia do evento, escaneando crachá sob
-- pressa e com internet ruim. Faltam menos de três semanas para
-- a feira; esse caminho é o que não pode quebrar.
--
-- Com uma coluna `tipo`, essas cinco peças não mudam uma linha.
-- O counselor é encontrado, exibido e salvo pelo mesmo código já
-- testado.
--
-- O PREÇO, declarado: a tabela `alunos` passa a guardar quem não
-- é aluno. O nome fica errado, e toda consulta que quiser só
-- alunos precisa de `where tipo = 'aluno'`. As consultas de
-- revisão em docs/inscricoes.md entram nessa conta.
--
-- Se um dia sobrar tempo, o certo é renomear para `credenciados`
-- — a tabela já carrega `turma`, `projeto`, `linkedin` da
-- plataforma original, então o nome já não descrevia bem o
-- conteúdo antes desta migration.
-- ============================================================

alter table public.alunos
  add column if not exists tipo text not null default 'aluno'
    check (tipo in ('aluno', 'counselor'));

comment on column public.alunos.tipo is
  'aluno = inscrição normal, com responsável e acompanhantes. '
  'counselor = College Counselor de outro colégio, sozinho. '
  'Quem quiser contar só alunos precisa filtrar por esta coluna.';

create index if not exists alunos_tipo_idx on public.alunos (tipo);

-- ------------------------------------------------------------
-- telefone volta, agora com dono
--
-- A 0007 derrubou `telefone` junto com turma, projeto, resumo e
-- linkedin: aluno não informa telefone próprio no formulário —
-- quem informa é o responsável, em responsavel_telefone. Estava
-- certo tirar.
--
-- O counselor muda isso: ele é o próprio contato, e o telefone
-- dele é dele. Volta como coluna opcional, preenchida apenas no
-- fluxo do counselor.
-- ------------------------------------------------------------
alter table public.alunos
  add column if not exists telefone text;

comment on column public.alunos.telefone is
  'Telefone próprio. Só o College Counselor preenche — aluno não '
  'informa telefone, o contato dele passa por responsavel_telefone.';

-- ------------------------------------------------------------
-- Versão do termo do counselor
--
-- Termo diferente do da família: ele é adulto consentindo pelos
-- próprios dados. Versão própria porque os dois textos mudam em
-- ritmos diferentes.
-- ------------------------------------------------------------
create or replace function public.versao_consentimento_counselor()
returns text
language sql
immutable
as $$
  select 'counselor-v1-2026'::text;
$$;

revoke execute on function public.versao_consentimento_counselor()
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- perfil_aluno: telefone, instituição e tipo
--
-- Três acréscimos, nenhuma remoção:
--
--   'telefone'   — recriada logo acima. É o contato do counselor.
--   'instituicao'— o colégio de origem. Para o counselor é o dado
--                  principal; para o aluno externo, é o mesmo
--                  `colegio` que já aparecia como 'escola'.
--   'tipo'       — o app usa para rotular o cartão.
--
-- Nível: counselor entra com nivel_compartilhamento = 3 e
-- consentimento marcado, então nivel_efetivo = 3 e o e-mail
-- aparece. É o que ele autorizou ao aceitar o termo.
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

    -- contexto escolar
    'escola',       case when public.nivel_efetivo(a) >= 1
                         then coalesce(a.colegio,
                                       case when a.aluno_alfacem
                                            then 'Rede Alfacem Global Academy' end) end,
    'instituicao',  case when public.nivel_efetivo(a) >= 1 then a.colegio end,
    'unidade',      case when public.nivel_efetivo(a) >= 1 then a.unidade end,
    'segmento',     case when public.nivel_efetivo(a) >= 1 then a.segmento end,
    'ano',          case when public.nivel_efetivo(a) >= 1 then a.ano_escolaridade end,

    -- qualificação
    'paises',       case when public.nivel_efetivo(a) >= 1 then to_jsonb(a.paises_interesse) end,
    'motivo',       case when public.nivel_efetivo(a) >= 1 then a.motivo end,
    'experiencia',  case when public.nivel_efetivo(a) >= 1 then a.experiencia_internacional end,
    'pathway',      case when public.nivel_efetivo(a) >= 1 then a.conhece_pathway end,

    -- contato direto
    'email',        case when public.nivel_efetivo(a) >= 2 then a.email end,
    'telefone',     case when public.nivel_efetivo(a) >= 2 then a.telefone end,

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
-- inscrever_counselor(dados)
--
-- Função separada, não um ramo dentro de inscrever_aluno. A
-- inscrição da família valida consentimento de menor, assinatura,
-- acompanhantes e cascata de unidade/segmento/ano — nada disso se
-- aplica aqui, e enfiar dois fluxos numa função só faria as duas
-- validações conviverem com `if tipo = ...` no meio.
--
-- Reaproveita o freio de inundação da 0013: mesma janela, mesma
-- tabela de tentativas.
-- ------------------------------------------------------------
create or replace function public.inscrever_counselor(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
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

  -- A tela também exige, mas a RPC é pública: quem decide é aqui.
  if coalesce((p_dados->>'ciencia_compartilhamento')::boolean, false) is not true then
    raise exception 'ciencia_obrigatoria';
  end if;

  if (select count(*) from alunos
       where tipo = 'counselor' and lower(email) = v_email) >= 3 then
    raise exception 'limite_de_inscricoes';
  end if;

  insert into inscricao_tentativas (ip_hash)
  values (coalesce(v_ip_hash, 'sem-origem'));

  delete from inscricao_tentativas where em < now() - interval '2 hours';

  insert into alunos (
    tipo, nome, email, telefone, colegio, aluno_alfacem,
    nivel_compartilhamento,
    -- O counselor é adulto e consente por si. A coluna se chama
    -- consentimento_responsavel por vir do fluxo da família; aqui
    -- ela significa "há consentimento válido para tratar estes
    -- dados", que é o que nivel_efetivo() consulta.
    consentimento_responsavel, consentimento_versao, consentimento_em,
    ciencia_compartilhamento,
    ativo
  ) values (
    'counselor', v_nome, v_email, v_telefone, v_instituicao, false,
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
-- Conferir depois de rodar
--
--   -- anon executa três coisas agora
--   select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
--    order by 1;          -- inscrever_aluno, inscrever_counselor, ping
--
--   -- as inscrições existentes continuam sendo 'aluno'
--   select tipo, count(*) from public.alunos group by tipo;
--
-- FILA DE REVISÃO, agora com os dois tipos
--
--   select tipo, nome,
--          case when tipo = 'counselor' then colegio
--               else coalesce(unidade, colegio) end as instituicao,
--          email, telefone, criado_em
--     from public.alunos
--    where not ativo
--    order by tipo, nome;
--
-- Para contar SÓ alunos, em qualquer consulta antiga:
--   ... where tipo = 'aluno'
-- ------------------------------------------------------------
