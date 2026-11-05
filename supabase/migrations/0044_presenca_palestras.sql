-- ============================================================
-- 0044 — Lista de presença das palestras
--
-- Quem pediu: a coordenação de bilinguismo precisa conferir, na
-- porta da sala, quem realmente apareceu em cada palestra. O
-- trabalho é feito no celular, em pé, durante o evento.
--
-- O QUE FALTAVA
--
-- palestra_inscricoes (0037) guardava a reserva da vaga e nada
-- mais: não havia onde registrar comparecimento. As colunas abaixo
-- copiam o padrão que alunos e acompanhantes já usam desde a 0025
-- — presente, presente_em, presente_por — para a tela de
-- credenciamento tratar as três listas do mesmo jeito.
--
-- POR QUE UM PAPEL SÓ PARA ISSO
--
-- A aba mora dentro de /credenciamento, mas quem vai usá-la não
-- trabalha na mesa de entrada. Dar 'atendente' a essas pessoas
-- abriria a fila inteira do evento — os ~800 inscritos com nome,
-- o cadastro no local, o crachá avulso. O papel 'palestras'
-- destranca as duas funções desta migration e mais nada: as outras
-- abas continuam atrás de exigir_credenciamento(), que não o
-- aceita.
--
-- O QUE A LISTA NÃO DEVOLVE
--
-- Nem e-mail, nem telefone. Para conferir quem entrou na sala o
-- nome basta, e a lista é de menores de idade. Quem precisa do
-- contato é o painel da organização, que já tem.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Onde registrar o comparecimento
--
-- "if not exists" para a migration poder ser rodada duas vezes sem
-- estragar nada — o SQL Editor não guarda o que já rodou.
--
-- presente_por aponta para a conta que marcou. "on delete set
-- null", e não cascade: revogar um acesso depois do evento não
-- pode apagar o registro de quem esteve presente.
-- ------------------------------------------------------------
alter table public.palestra_inscricoes
  add column if not exists presente     boolean not null default false,
  add column if not exists presente_em  timestamptz,
  add column if not exists presente_por uuid references public.avaliadores(id) on delete set null;

create index if not exists palestra_inscricoes_presente_idx
  on public.palestra_inscricoes (palestra_codigo, presente);

-- ------------------------------------------------------------
-- 2. O papel
-- ------------------------------------------------------------
alter table public.avaliadores
  drop constraint if exists avaliadores_papel_check;

alter table public.avaliadores
  add constraint avaliadores_papel_check
  check (papel in ('avaliador', 'gestor', 'diretoria', 'supervisor', 'atendente', 'palestras'));

comment on column public.avaliadores.papel is
  'avaliador  = representante de universidade, escaneia crachá. '
  'atendente  = equipe da mesa de entrada, SÓ o credenciamento. '
  'palestras  = SÓ a lista de presença das palestras. '
  'gestor     = organização: painel de inscrições e credenciamento. '
  'supervisor = tela do evento inteira, mas só CRIA conta de '
  'representante — não muda papel, não revoga, não apaga. '
  'diretoria  = tudo.';

-- ------------------------------------------------------------
-- 3. A guarda, no padrão da 0043
--
-- Sem grant: só é chamada de dentro de outras security definer.
-- Sem o revoke ela nasceria executável por PUBLIC e viraria um
-- oráculo de "que papel tem esta sessão?".
-- ------------------------------------------------------------
create or replace function public.exigir_palestras()
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
  if not exists (select 1 from avaliadores
                  where id = v_id
                    and papel in ('palestras', 'diretoria')) then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;

revoke execute on function public.exigir_palestras() from public, anon;

-- ------------------------------------------------------------
-- 4. A lista, agrupada por palestra
--
-- Uma chamada só devolve tudo: são 70 inscritos, e no salão a
-- internet disputa com centenas de celulares. Lista em memória
-- continua respondendo à busca; consulta a cada tecla, não.
-- ------------------------------------------------------------
create or replace function public.lista_presenca_palestras()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_palestras();
begin
  return jsonb_build_object(
    'gerado_em', now(),
    'palestras', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'codigo',    p.codigo,
                 'titulo',    p.titulo,
                 'palestrante', p.palestrante,
                 'vagas',     p.vagas,
                 'inscritos', (select count(*) from palestra_inscricoes i
                                where i.palestra_codigo = p.codigo),
                 'presentes', (select count(*) from palestra_inscricoes i
                                where i.palestra_codigo = p.codigo and i.presente),
                 'pessoas',   coalesce((
                   select jsonb_agg(
                            jsonb_build_object(
                              'id',       i.id,
                              'nome',     i.nome,
                              'presente', i.presente)
                            order by public.chave_nome(i.nome))
                     from palestra_inscricoes i
                    where i.palestra_codigo = p.codigo
                 ), '[]'::jsonb))
               order by p.ordem)
        from palestras p
       where p.ativa
    ), '[]'::jsonb));
end;
$$;

-- ------------------------------------------------------------
-- 5. Marcar e desmarcar
--
-- Desmarcar existe porque o erro na porta é inevitável: dois nomes
-- parecidos, o dedo escorrega. Sem o caminho de volta, a correção
-- viraria pedido para a diretoria no meio da palestra.
-- ------------------------------------------------------------
create or replace function public.marcar_presenca_palestra(
  p_id       uuid,
  p_presente boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id   uuid := public.exigir_palestras();
  v_nome text;
begin
  update palestra_inscricoes
     set presente     = p_presente,
         presente_em  = case when p_presente then now() else null end,
         presente_por = case when p_presente then v_id else null end
   where id = p_id
  returning nome into v_nome;

  if v_nome is null then
    raise exception 'nao_encontrado';
  end if;

  return jsonb_build_object('ok', true, 'nome', v_nome, 'presente', p_presente);
end;
$$;

revoke execute on function public.lista_presenca_palestras()             from public, anon;
revoke execute on function public.marcar_presenca_palestra(uuid, boolean) from public, anon;

grant execute on function public.lista_presenca_palestras()             to authenticated;
grant execute on function public.marcar_presenca_palestra(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- 6. As duas funções de conta, só para aceitarem o papel novo
--
-- Corpos extraídos da 0043 por script, com uma troca: a lista de
-- papéis válidos. Nenhuma outra linha mudou.
-- ------------------------------------------------------------
create or replace function public.admin_papel(p_id uuid, p_papel text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.exigir_diretoria();
begin
  if p_papel not in ('avaliador', 'gestor', 'diretoria', 'supervisor', 'atendente', 'palestras') then
    raise exception 'papel_invalido';
  end if;

  /* Ninguém rebaixa a si mesmo: sair de diretoria por engano
     tranca a pessoa fora desta tela, e só outra diretoria — ou o
     SQL Editor — poderia devolver. */
  if p_id = v_admin and p_papel <> 'diretoria' then
    raise exception 'nao_rebaixa_a_si';
  end if;

  update avaliadores set papel = p_papel where id = p_id;
  if not found then raise exception 'nao_encontrado'; end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_criar_conta(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_admin  uuid := public.exigir_gestao();
  v_quem   text;
  v_alvo   text;
  v_nome   text := nullif(trim(p_dados->>'nome'), '');
  v_email  text := lower(nullif(trim(p_dados->>'email'), ''));
  v_org    text := nullif(trim(p_dados->>'organizacao'), '');
  v_papel  text := coalesce(nullif(trim(p_dados->>'papel'), ''), 'avaliador');
  v_id     uuid;
  v_novo   boolean := false;
begin
  select papel into v_quem from public.avaliadores where id = v_admin;

  if v_nome is null then
    raise exception 'nome_obrigatorio';
  end if;
  if v_email is null
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;
  if v_papel not in ('avaliador', 'gestor', 'diretoria', 'supervisor', 'atendente', 'palestras') then
    raise exception 'papel_invalido';
  end if;

  -- (a) teto de papel
  if v_quem is distinct from 'diretoria' and v_papel <> 'avaliador' then
    raise exception 'papel_acima_do_seu';
  end if;

  select id into v_id from auth.users where lower(email) = v_email;

  if v_id is not null and v_quem is distinct from 'diretoria' then
    -- (c) não mexe na própria linha
    if v_id = v_admin then
      raise exception 'nao_altera_a_si';
    end if;
    -- (b) não escreve por cima de conta de outro nível
    select papel into v_alvo from public.avaliadores where id = v_id;
    if v_alvo is not null and v_alvo <> 'avaliador' then
      raise exception 'conta_protegida';
    end if;
  end if;

  if v_id is null then
    v_id := gen_random_uuid();
    v_novo := true;

    insert into auth.users (
      id, instance_id, aud, role, email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) values (
      v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', v_email,
      null,
      now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('nome', v_nome),
      now(), now()
    );
  end if;

  insert into public.avaliadores (id, nome, email, organizacao, papel)
  values (v_id, v_nome, v_email, v_org, v_papel)
  on conflict (id) do update
    set nome = excluded.nome,
        email = excluded.email,
        organizacao = excluded.organizacao,
        papel = excluded.papel;

  return jsonb_build_object(
    'ok', true, 'id', v_id, 'nome', v_nome, 'email', v_email,
    'papel', v_papel, 'novo', v_novo);
end;
$$;

-- ------------------------------------------------------------
-- 7. Conferência depois de aplicar
--
--   -- as colunas entraram?
--   select column_name, data_type from information_schema.columns
--    where table_name = 'palestra_inscricoes' order by ordinal_position;
--
--   -- quem está presente em cada palestra
--   select p.titulo,
--          count(*) filter (where i.presente) as presentes,
--          count(*)                            as inscritos
--     from palestras p
--     left join palestra_inscricoes i on i.palestra_codigo = p.codigo
--    group by p.titulo order by p.titulo;
--
--   -- as contas com o papel novo
--   select nome, email, papel from public.avaliadores
--    where papel = 'palestras';
-- ------------------------------------------------------------
