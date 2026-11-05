-- ============================================================
-- 0037 — Inscrição nas palestras
--
-- Duas palestras simultâneas, 50 lugares cada, uma pessoa em uma
-- só. A inscrição sai de um comunicado disparado para as
-- famílias: todo mundo recebe junto, e boa parte clica no mesmo
-- minuto.
--
-- É esse minuto que define o desenho daqui.
--
-- POR QUE A CONTAGEM É TRANCADA
--
-- "Conta quantos já entraram; se for menos de 50, insere" parece
-- suficiente e não é. Vinte pessoas fazendo isso ao mesmo tempo
-- leem 49 e inserem as vinte — a sala estoura e ninguém percebe
-- até o dia.
--
-- `pg_advisory_xact_lock` serializa por palestra: quem chega
-- espera a vez de contar, e a espera é de milissegundos. As duas
-- palestras têm travas diferentes, então uma não segura a outra.
--
-- UMA POR PESSOA, E POR E-MAIL
--
-- O índice único é sobre o e-mail em minúsculas, sem olhar a
-- palestra: entrar na segunda depois de já estar na primeira é o
-- mesmo erro que entrar duas vezes na mesma. A mensagem devolvida
-- diz em qual delas a pessoa já está, senão ela tenta de novo
-- achando que foi engano.
-- ============================================================

create table if not exists public.palestras (
  codigo       text primary key,
  titulo       text not null,
  palestrante  text not null,
  vagas        integer not null check (vagas > 0),
  ordem        smallint not null default 0,
  ativa        boolean not null default true
);

create table if not exists public.palestra_inscricoes (
  id              uuid primary key default gen_random_uuid(),
  palestra_codigo text not null references public.palestras(codigo),
  nome            text not null,
  email           text not null,
  telefone        text,
  criado_em       timestamptz not null default now()
);

-- Uma inscrição por pessoa, em qualquer uma das palestras.
create unique index if not exists palestra_inscricoes_email_idx
  on public.palestra_inscricoes (lower(email));

create index if not exists palestra_inscricoes_palestra_idx
  on public.palestra_inscricoes (palestra_codigo);

-- RLS ligada e sem policy: ninguém lê nem escreve direto. Tudo
-- passa pelas funções abaixo, como o resto do sistema (0002).
alter table public.palestras           enable row level security;
alter table public.palestra_inscricoes enable row level security;
revoke all on public.palestras           from anon, authenticated;
revoke all on public.palestra_inscricoes from anon, authenticated;

insert into public.palestras (codigo, titulo, palestrante, vagas, ordem) values
  ('fgv-emap',
   'FGV EMAp — Ciência de Dados e Inteligência Artificial',
   'Moacyr Silva', 50, 1),
  ('educationusa',
   'EducationUSA — Getting Started: os primeiros passos rumo ao ensino superior nos Estados Unidos',
   'Fernanda Freitas', 50, 2)
on conflict (codigo) do update
  set titulo = excluded.titulo,
      palestrante = excluded.palestrante,
      vagas = excluded.vagas;

-- ------------------------------------------------------------
-- palestras_abertas(): o que a tela mostra antes de escolher
--
-- Pública. Devolve título, palestrante e quantas vagas restam —
-- nada de nome de quem já se inscreveu.
-- ------------------------------------------------------------
create or replace function public.palestras_abertas()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'codigo',      p.codigo,
             'titulo',      p.titulo,
             'palestrante', p.palestrante,
             'vagas',       p.vagas,
             'ocupadas',    (select count(*) from palestra_inscricoes i
                              where i.palestra_codigo = p.codigo),
             'restantes',   greatest(0, p.vagas - (select count(*) from palestra_inscricoes i
                                                    where i.palestra_codigo = p.codigo))
           ) order by p.ordem), '[]'::jsonb)
    from palestras p
   where p.ativa;
$$;

revoke execute on function public.palestras_abertas() from public;
grant  execute on function public.palestras_abertas() to anon, authenticated;

-- ------------------------------------------------------------
-- inscrever_palestra(dados)
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

  select * into v_p from palestras where codigo = v_codigo and ativa;
  if not found then
    raise exception 'palestra_invalida';
  end if;

  /* Trava por palestra. Só depois dela a contagem vale: sem isso,
     vinte pedidos simultâneos leem o mesmo número e todos passam. */
  perform pg_advisory_xact_lock(hashtext('palestra:' || v_codigo));

  /* A checagem de e-mail vem DEPOIS da trava e ANTES da contagem.
     Assim quem tenta duas vezes não consome a leitura de vaga, e a
     mensagem diz onde a pessoa já está. */
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

  insert into palestra_inscricoes (palestra_codigo, nome, email, telefone)
  values (v_codigo, v_nome, v_email, v_tel);

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
-- lista_palestras(): para a organização, com nomes
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
               'inscritos', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'nome', i.nome, 'email', i.email,
                          'telefone', i.telefone, 'em', i.criado_em)
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
-- OPERAÇÃO
--
-- Mudar o número de vagas:
--   update public.palestras set vagas = 60 where codigo = 'fgv-emap';
--
-- Fechar uma palestra sem apagar quem já entrou:
--   update public.palestras set ativa = false where codigo = 'fgv-emap';
--
-- Tirar alguém (desistência), liberando a vaga:
--   delete from public.palestra_inscricoes where lower(email) = 'quem@for.com';
--
-- Quem se inscreveu, por palestra:
--   select p.titulo, i.nome, i.email, i.criado_em
--     from public.palestra_inscricoes i
--     join public.palestras p on p.codigo = i.palestra_codigo
--    order by p.ordem, i.criado_em;
--
-- Cruzar com a inscrição na feira (quem não está inscrito no
-- evento mas pegou vaga na palestra):
--   select i.nome, i.email
--     from public.palestra_inscricoes i
--    where not exists (
--      select 1 from public.alunos a
--       where lower(coalesce(a.responsavel_email, a.email)) = lower(i.email));
-- ------------------------------------------------------------
