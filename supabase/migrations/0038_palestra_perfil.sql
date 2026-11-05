-- ============================================================
-- 0038 — Quem é quem na palestra
--
-- A tela pedia "nome completo do aluno". Está errado: quem assiste
-- pode ser o responsável, e pode ser um convidado que nem está
-- inscrito na feira. A palestra não é só dos alunos.
--
-- Entra uma coluna `perfil`, preenchida por quem se inscreve. Não
-- muda nenhuma regra — continua uma inscrição por e-mail, em uma
-- palestra só — mas passa a responder a pergunta que a direção faz
-- depois: quem esteve na sala?
--
-- 'aluno' como padrão porque é a maioria esperada, e porque as
-- inscrições feitas antes desta migration (se houver) são de
-- alunos: a tela dizia isso.
-- ============================================================

alter table public.palestra_inscricoes
  add column if not exists perfil text not null default 'aluno';

alter table public.palestra_inscricoes
  drop constraint if exists palestra_inscricoes_perfil_check;

alter table public.palestra_inscricoes
  add constraint palestra_inscricoes_perfil_check
  check (perfil in ('aluno', 'responsavel', 'externo'));

comment on column public.palestra_inscricoes.perfil is
  'aluno | responsavel | externo (convidado que não é da feira). '
  'Serve para medir a composição da sala, não muda regra de vaga.';

-- ------------------------------------------------------------
-- inscrever_palestra(): igual à 0037, mais o perfil
-- ------------------------------------------------------------
create or replace function public.inscrever_palestra(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_codigo   text := nullif(trim(p_dados->>'palestra'), '');
  v_nome     text := nullif(trim(p_dados->>'nome'), '');
  v_email    text := lower(nullif(trim(p_dados->>'email'), ''));
  v_tel      text := nullif(trim(p_dados->>'telefone'), '');
  v_perfil   text := coalesce(nullif(trim(p_dados->>'perfil'), ''), 'aluno');
  v_p        record;
  v_ja       record;
  v_ocupadas integer;
begin
  if v_nome is null or array_length(string_to_array(v_nome, ' '), 1) < 2 then
    raise exception 'nome_incompleto';
  end if;
  if v_email is null
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;
  if v_perfil not in ('aluno', 'responsavel', 'externo') then
    raise exception 'perfil_invalido';
  end if;

  select * into v_p from palestras where codigo = v_codigo and ativa;
  if not found then
    raise exception 'palestra_invalida';
  end if;

  /* Trava por palestra. Só depois dela a contagem vale: sem isso,
     vinte pedidos simultâneos leem o mesmo número e todos passam. */
  perform pg_advisory_xact_lock(hashtext('palestra:' || v_codigo));

  select i.palestra_codigo, p.titulo
    into v_ja
    from palestra_inscricoes i
    join palestras p on p.codigo = i.palestra_codigo
   where lower(i.email) = v_email;

  if found then
    return jsonb_build_object(
      'ok', false,
      'motivo', 'ja_inscrito',
      'palestra', v_ja.palestra_codigo,
      'titulo', v_ja.titulo);
  end if;

  select count(*) into v_ocupadas
    from palestra_inscricoes where palestra_codigo = v_codigo;

  if v_ocupadas >= v_p.vagas then
    return jsonb_build_object('ok', false, 'motivo', 'lotada', 'titulo', v_p.titulo);
  end if;

  insert into palestra_inscricoes (palestra_codigo, nome, email, telefone, perfil)
  values (v_codigo, v_nome, v_email, v_tel, v_perfil);

  return jsonb_build_object(
    'ok', true,
    'titulo', v_p.titulo,
    'palestrante', v_p.palestrante,
    'posicao', v_ocupadas + 1,
    'restantes', v_p.vagas - v_ocupadas - 1);
end;
$$;

revoke execute on function public.inscrever_palestra(jsonb) from public;
grant  execute on function public.inscrever_palestra(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- lista_palestras(): agora com o perfil de cada um e o resumo
--
-- O resumo vem pronto do banco em vez de ser contado na tela:
-- é a pergunta que a direção faz, e contar em dois lugares é como
-- dois números diferentes aparecem para a mesma coisa.
-- ------------------------------------------------------------
create or replace function public.lista_palestras()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_gestor();
begin
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'codigo',      p.codigo,
               'titulo',      p.titulo,
               'palestrante', p.palestrante,
               'vagas',       p.vagas,
               'resumo', (
                 select jsonb_build_object(
                          'alunos',       count(*) filter (where i.perfil = 'aluno'),
                          'responsaveis', count(*) filter (where i.perfil = 'responsavel'),
                          'externos',     count(*) filter (where i.perfil = 'externo'))
                   from palestra_inscricoes i
                  where i.palestra_codigo = p.codigo
               ),
               'inscritos', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'nome', i.nome, 'email', i.email,
                          'telefone', i.telefone, 'perfil', i.perfil,
                          'em', i.criado_em)
                        order by i.criado_em)
                   from palestra_inscricoes i
                  where i.palestra_codigo = p.codigo), '[]'::jsonb)
             ) order by p.ordem)
      from palestras p
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.lista_palestras() from public, anon;
grant  execute on function public.lista_palestras() to authenticated;

-- ------------------------------------------------------------
-- QUEM ESTEVE NA SALA
--
--   select p.titulo,
--          count(*) filter (where i.perfil = 'aluno')       as alunos,
--          count(*) filter (where i.perfil = 'responsavel') as responsaveis,
--          count(*) filter (where i.perfil = 'externo')     as externos,
--          count(*)                                          as total
--     from public.palestras p
--     left join public.palestra_inscricoes i on i.palestra_codigo = p.codigo
--    group by p.titulo, p.ordem
--    order by p.ordem;
-- ------------------------------------------------------------
