-- ============================================================
-- 0001 — Schema base
-- Referência: requisitos-plataforma-avaliadores.md, seção 6
-- ============================================================

-- ------------------------------------------------------------
-- Utilitário: código curto legível, sem 0/O/1/I
-- Alfabeto de 32 caracteres, 6 posições => 32^6 ~ 1,07 bilhão
-- ------------------------------------------------------------
create or replace function public.gen_codigo_curto()
returns text
language sql
volatile
as $$
  select string_agg(
    substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
           (floor(random() * 32) + 1)::int, 1), '')
  from generate_series(1, 6);
$$;

-- ------------------------------------------------------------
-- Utilitário: token opaco do crachá
-- 32 caracteres hex a partir de gen_random_uuid() (função nativa
-- do Postgres 13+). Evita depender da extensão pgcrypto, que no
-- Supabase vive no schema `extensions` e quebraria o DEFAULT se
-- o search_path mudasse.
-- ------------------------------------------------------------
create or replace function public.gen_cracha_token()
returns text
language sql
volatile
as $$
  select replace(gen_random_uuid()::text, '-', '');
$$;

-- ------------------------------------------------------------
-- AVALIADORES — espelha auth.users
-- Populado antes do evento (workflow n8n / Admin API).
-- ------------------------------------------------------------
create table public.avaliadores (
  id           uuid primary key references auth.users(id) on delete cascade,
  nome         text not null,
  email        text not null unique,
  organizacao  text,
  criado_em    timestamptz not null default now()
);

-- ------------------------------------------------------------
-- ALUNOS — nunca autenticam, só existem como registro
-- ------------------------------------------------------------
create table public.alunos (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  turma         text,
  projeto       text,
  resumo        text,           -- pitch de 1-2 linhas
  email         text,
  telefone      text,
  linkedin      text,

  -- 0 = não autoriza | 1 = acadêmico | 2 = +e-mail | 3 = tudo
  nivel_compartilhamento smallint not null default 0
    check (nivel_compartilhamento between 0 and 3),

  -- consentimento do responsável, coletado na inscrição
  consentimento_responsavel boolean not null default false,
  consentimento_versao      text,
  consentimento_em          timestamptz,

  cracha_token  text not null unique default public.gen_cracha_token(),
  codigo_curto  text not null unique default public.gen_codigo_curto(),
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

-- Busca por código curto digitado chega sempre em maiúsculas
-- (a função de leitura aplica upper/trim antes de comparar).
comment on column public.alunos.codigo_curto is
  'Sempre em maiúsculas. Alfabeto sem 0/O/1/I.';

-- ------------------------------------------------------------
-- CONTATOS SALVOS — PK composta = upsert natural
-- ------------------------------------------------------------
create table public.contatos_salvos (
  avaliador_id  uuid not null default auth.uid()
                references public.avaliadores(id) on delete cascade,
  aluno_id      uuid not null
                references public.alunos(id) on delete cascade,
  nota          smallint check (nota between 1 and 5),
  comentario    text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  primary key (avaliador_id, aluno_id)
);

create index on public.contatos_salvos (avaliador_id, criado_em desc);

-- `atualizado_em` precisa de trigger: o upsert do cliente manda
-- só nota e comentário, então a coluna ficaria congelada na data
-- do primeiro scan.
create or replace function public.tocar_atualizado_em()
returns trigger
language plpgsql
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

create trigger contatos_salvos_atualizado_em
  before update on public.contatos_salvos
  for each row execute function public.tocar_atualizado_em();

-- ------------------------------------------------------------
-- LOG DE ACESSO — accountability LGPD
-- Também é dado pessoal: entra no mesmo prazo de retenção.
-- ------------------------------------------------------------
create table public.log_acesso (
  id           bigserial primary key,
  avaliador_id uuid references public.avaliadores(id),
  aluno_id     uuid references public.alunos(id),
  em           timestamptz not null default now()
);

create index on public.log_acesso (avaliador_id, em desc);
create index on public.log_acesso (aluno_id, em desc);
