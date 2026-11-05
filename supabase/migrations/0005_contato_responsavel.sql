-- ============================================================
-- 0005 — Contato do responsável
--
-- Caso que o modelo original não previa: aluno que não autoriza
-- compartilhar os próprios dados, mas cujo responsável autoriza
-- ser contatado. Existe canal, e o avaliador precisa conseguir
-- salvar o contato — o que hoje o nível 0 impede.
--
-- O compartilhamento do responsável é uma decisão INDEPENDENTE
-- do nível do aluno. Um não implica o outro em nenhuma direção.
-- ============================================================

alter table public.alunos
  add column responsavel_nome         text,
  add column responsavel_email        text,
  add column responsavel_telefone     text,
  add column compartilhar_responsavel boolean not null default false;

comment on column public.alunos.compartilhar_responsavel is
  'Opt-in próprio, independente de nivel_compartilhamento. '
  'Continua exigindo consentimento_responsavel = true.';

-- ------------------------------------------------------------
-- O contato do responsável está liberado?
--
-- Exige as duas coisas: o opt-in específico E o consentimento
-- registrado. Mesma lógica defensiva de nivel_efetivo() — sem
-- consentimento na ficha, nada sai, qualquer que seja a coluna.
-- ------------------------------------------------------------
create or replace function public.responsavel_liberado(a public.alunos)
returns boolean
language sql
immutable
as $$
  select a.consentimento_responsavel and a.compartilhar_responsavel;
$$;

-- ------------------------------------------------------------
-- Existe algum canal para salvar este contato?
--
-- Nível 1 já vale: mesmo sem dado de contato, o avaliador
-- registra nota e comentário sobre o projeto. O que não pode é
-- salvar quem não autorizou nada.
-- ------------------------------------------------------------
create or replace function public.pode_salvar(a public.alunos)
returns boolean
language sql
immutable
as $$
  select public.nivel_efetivo(a) >= 1 or public.responsavel_liberado(a);
$$;

-- ------------------------------------------------------------
-- perfil_aluno passa a devolver o bloco do responsável
--
-- `pode_salvar` vai no JSON para o cliente não ter que deduzir a
-- regra a partir do nível. Regra duplicada no JavaScript é regra
-- que sai de sincronia com o servidor.
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
    'turma',        case when public.nivel_efetivo(a) >= 1 then a.turma    end,
    'projeto',      case when public.nivel_efetivo(a) >= 1 then a.projeto  end,
    'resumo',       case when public.nivel_efetivo(a) >= 1 then a.resumo   end,
    'email',        case when public.nivel_efetivo(a) >= 2 then a.email    end,
    'telefone',     case when public.nivel_efetivo(a) >= 3 then a.telefone end,
    'linkedin',     case when public.nivel_efetivo(a) >= 3 then a.linkedin end,

    -- Bloco do responsável: campo nulo simplesmente não aparece
    -- na tela, então quem informou só o e-mail não precisa de
    -- outro nível para isso.
    'responsavel_nome',     case when public.responsavel_liberado(a) then a.responsavel_nome     end,
    'responsavel_email',    case when public.responsavel_liberado(a) then a.responsavel_email    end,
    'responsavel_telefone', case when public.responsavel_liberado(a) then a.responsavel_telefone end,

    'pode_salvar',  public.pode_salvar(a),
    'ja_salvo',     p_ja_salvo
  );
$$;

-- ------------------------------------------------------------
-- salvar_contato passa a aceitar o canal do responsável
-- ------------------------------------------------------------
create or replace function public.salvar_contato(
  p_codigo     text,
  p_nota       smallint default null,
  p_comentario text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_avaliador uuid := public.exigir_avaliador();
  v alunos%rowtype;
begin
  select * into v from alunos
   where ativo
     and (cracha_token = lower(trim(p_codigo))
          or codigo_curto = upper(trim(p_codigo)));

  if not found then
    raise exception 'cracha_nao_encontrado';
  end if;

  -- Antes era `nivel_efetivo(v) = 0`. Agora quem tem apenas o
  -- responsável liberado também pode ser salvo.
  if not public.pode_salvar(v) then
    raise exception 'aluno_nao_autoriza';
  end if;

  insert into contatos_salvos (avaliador_id, aluno_id, nota, comentario)
  values (v_avaliador, v.id, p_nota, nullif(trim(coalesce(p_comentario, '')), ''))
  on conflict (avaliador_id, aluno_id) do update
     set nota       = coalesce(excluded.nota, contatos_salvos.nota),
         comentario = coalesce(excluded.comentario, contatos_salvos.comentario);

  return public.perfil_aluno(v, true);
end;
$$;

-- ------------------------------------------------------------
-- Permissões das funções novas
--
-- create or replace preserva os grants das existentes; as duas
-- criadas agora nascem com EXECUTE para PUBLIC.
-- ------------------------------------------------------------
revoke execute on function public.responsavel_liberado(public.alunos) from public, anon, authenticated;
revoke execute on function public.pode_salvar(public.alunos)          from public, anon, authenticated;
