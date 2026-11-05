-- ============================================================
-- 0003 — Funções de acesso (SECURITY DEFINER)
-- Referência: requisitos-plataforma-avaliadores.md, seção 7.3
--
-- RLS filtra LINHA, não COLUNA. O nível de compartilhamento
-- decide quais CAMPOS aparecem, então RLS sozinha não resolve.
-- Estas funções são a única porta de entrada em `alunos`.
-- ============================================================

-- ------------------------------------------------------------
-- Guarda comum: sessão válida de avaliador cadastrado
-- ------------------------------------------------------------
create or replace function public.exigir_avaliador()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := auth.uid();
begin
  if v_id is null then
    raise exception 'nao_autenticado';
  end if;
  if not exists (select 1 from avaliadores where id = v_id) then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- Nível efetivo de um aluno
--
-- Sem consentimento registrado do responsável, o nível cai para
-- 0 independentemente do que estiver na coluna. São menores de
-- idade: um erro de importação de CSV que marque nivel=3 em quem
-- não consentiu não pode virar vazamento de telefone.
-- ------------------------------------------------------------
create or replace function public.nivel_efetivo(a public.alunos)
returns smallint
language sql
immutable
as $$
  select case when a.consentimento_responsavel
              then a.nivel_compartilhamento
              else 0::smallint
         end;
$$;

-- ------------------------------------------------------------
-- Monta o JSON do aluno com SOMENTE os campos autorizados
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
    'ja_salvo',     p_ja_salvo
  );
$$;

-- ------------------------------------------------------------
-- buscar_aluno(codigo) — leitura de perfil + log, uma transação
--
-- Aceita tanto o token do QR quanto o código curto digitado.
-- ------------------------------------------------------------
create or replace function public.buscar_aluno(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_avaliador uuid := public.exigir_avaliador();
  v alunos%rowtype;
  c contatos_salvos%rowtype;
begin
  select * into v from alunos
   where ativo
     and (cracha_token = lower(trim(p_codigo))
          or codigo_curto = upper(trim(p_codigo)));

  if not found then
    raise exception 'cracha_nao_encontrado';
  end if;

  -- registra o acesso na mesma transação da leitura
  insert into log_acesso (avaliador_id, aluno_id) values (v_avaliador, v.id);

  -- Nota e comentário que ESTE avaliador já escreveu, para o
  -- formulário abrir preenchido em vez de em branco num re-scan.
  select * into c from contatos_salvos
   where avaliador_id = v_avaliador and aluno_id = v.id;

  return public.perfil_aluno(v, found)
         || jsonb_build_object(
              'minha_nota',       c.nota,
              'meu_comentario',   c.comentario
            );
end;
$$;

-- ------------------------------------------------------------
-- salvar_contato(codigo, nota, comentario)
--
-- Salva pelo CÓDIGO, não pelo aluno_id. Isso é o que torna a
-- fila offline possível: o dispositivo enfileira o código lido
-- do crachá e sincroniza depois, sem nunca ter conseguido
-- resolver o aluno_id (o que exigiria rede no momento do scan).
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

  if public.nivel_efetivo(v) = 0 then
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
-- listar_meus_contatos() — tela "Meus contatos"
--
-- `alunos` não tem policy de select, então o cliente não
-- consegue nem o nome de quem ele mesmo salvou. Esta função
-- devolve a lista já filtrada por nível.
-- ------------------------------------------------------------
create or replace function public.listar_meus_contatos()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_avaliador uuid := public.exigir_avaliador();
begin
  return coalesce(
    (select jsonb_agg(
              public.perfil_aluno(a, true)
              || jsonb_build_object(
                   'nota',       c.nota,
                   'comentario', c.comentario,
                   'salvo_em',   c.criado_em
                 )
              order by c.criado_em desc)
       from contatos_salvos c
       join alunos a on a.id = c.aluno_id
      where c.avaliador_id = v_avaliador),
    '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------------
-- Permissões
--
-- Funções em Postgres nascem com EXECUTE para PUBLIC. Sem o
-- revoke abaixo, a chave `anon` — que está no HTML, à vista de
-- todos — chamaria buscar_aluno() direto.
-- ------------------------------------------------------------
revoke execute on function public.exigir_avaliador()                     from public, anon;
revoke execute on function public.buscar_aluno(text)                     from public, anon;
revoke execute on function public.salvar_contato(text, smallint, text)   from public, anon;
revoke execute on function public.listar_meus_contatos()                 from public, anon;
revoke execute on function public.gen_codigo_curto()                     from public, anon, authenticated;
revoke execute on function public.gen_cracha_token()                     from public, anon, authenticated;

-- Auxiliares internas: recebem uma linha de `alunos` como argumento
-- e são chamadas de dentro das funções DEFINER (que rodam como owner).
-- Nenhum cliente precisa alcançá-las.
revoke execute on function public.nivel_efetivo(public.alunos)          from public, anon, authenticated;
revoke execute on function public.perfil_aluno(public.alunos, boolean)  from public, anon, authenticated;

grant execute on function public.buscar_aluno(text)                   to authenticated;
grant execute on function public.salvar_contato(text, smallint, text) to authenticated;
grant execute on function public.listar_meus_contatos()               to authenticated;

-- gen_codigo_curto / gen_cracha_token são DEFAULT de coluna em
-- `alunos`. O DEFAULT roda com os privilégios de quem insere —
-- o revoke acima em PUBLIC deixaria o import de alunos pelo n8n
-- (service_role) quebrando com "permission denied for function".
grant execute on function public.gen_codigo_curto() to service_role;
grant execute on function public.gen_cracha_token() to service_role;
