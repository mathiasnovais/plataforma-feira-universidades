-- ============================================================
-- 0017 — Painel com nomes, para quem tem permissão
--
-- A 0016 abriu um painel de contagens, sem dado pessoal, aberto a
-- quem tiver o link. A direção precisa ver mais: quem se
-- inscreveu, de onde, com que contato, e onde há duplicata.
--
-- Isso não pode ficar atrás de link secreto. Fica atrás de login.
--
-- REUSA O QUE JÁ EXISTE, e não inventa autenticação nova:
--
--   - a tabela `avaliadores`, que já liga a auth.users
--   - o login por e-mail + código de 6 dígitos do app do avaliador
--   - a entrega do código pelo n8n (n8n/enviar-otp.json)
--   - Enable signup = OFF, então ninguém se cadastra sozinho:
--     quem não foi criado por script não entra
--
-- O que muda é uma coluna de papel. Avaliador continua avaliador;
-- gestor enxerga o painel.
-- ============================================================

alter table public.avaliadores
  add column if not exists papel text not null default 'avaliador'
    check (papel in ('avaliador', 'gestor'));

comment on column public.avaliadores.papel is
  'avaliador = representante de universidade, escaneia crachá. '
  'gestor = direção e organização, enxerga o painel com nomes. '
  'Gestor NÃO ganha acesso ao app de escanear por isso, nem o '
  'contrário: são funções separadas, cada uma com sua checagem.';

-- ------------------------------------------------------------
-- exigir_gestor()
--
-- Igual à exigir_avaliador da 0003, com a checagem do papel. Duas
-- funções separadas de propósito: assim dá para ler, em qualquer
-- RPC, qual é a exigência daquele caminho — sem parâmetro booleano
-- decidindo permissão no meio do código.
-- ------------------------------------------------------------
create or replace function public.exigir_gestor()
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
  if not exists (select 1 from avaliadores where id = v_id and papel = 'gestor') then
    raise exception 'sem_permissao';
  end if;
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- painel_gestor()
--
-- Os números da 0016 mais o que tem nome. Devolve tudo numa
-- chamada só para a página não precisar orquestrar várias.
--
-- Telefone NÃO entra. Para acompanhar inscrição e achar
-- duplicata, nome e e-mail bastam — e telefone de menor é o dado
-- mais sensível que a tabela guarda. Quem precisar dele abre o
-- Table Editor, onde o acesso é nominal e auditável.
-- ------------------------------------------------------------
create or replace function public.painel_gestor()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_gestor();
begin
  return public.painel_publico() || jsonb_build_object(

    'inscricoes', (
      select coalesce(jsonb_agg(linha order by linha->>'criado_em' desc), '[]'::jsonb)
        from (
          select jsonb_build_object(
                   'tipo',        a.tipo,
                   'nome',        a.nome,
                   'onde',        case when a.tipo = 'counselor' then a.colegio
                                       else coalesce(a.unidade, a.colegio) end,
                   'ano',         a.ano_escolaridade,
                   'responsavel', a.responsavel_nome,
                   'contato',     coalesce(a.responsavel_email, a.email),
                   'acompanhantes', (select count(*) from acompanhantes c where c.aluno_id = a.id),
                   'ativo',       a.ativo,
                   'email_enviado', a.email_confirmacao_em is not null,
                   'criado_em',   a.criado_em
                 ) as linha
            from alunos a
           order by a.criado_em desc
           limit 500
        ) q
    ),

    -- Família que preenche duas vezes por achar que não enviou é
    -- o erro mais comum, e vira dois crachás para a mesma pessoa.
    'duplicatas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', nome, 'vezes', vezes, 'contatos', contatos)
               order by vezes desc), '[]'::jsonb)
        from (select min(a.nome) as nome, count(*) as vezes,
                     string_agg(distinct coalesce(a.responsavel_email, a.email), ' · ') as contatos
                from alunos a
               where a.nome is not null and trim(a.nome) <> ''
               group by lower(trim(a.nome))
              having count(*) > 1) q
    ),

    -- Sem canal nenhum: recebe crachá, aparece para o
    -- representante, mas não há como salvar o contato.
    'sem_contato', (
      select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'tipo', tipo)
                                order by nome), '[]'::jsonb)
        from alunos
       where coalesce(nullif(trim(responsavel_email), ''), nullif(trim(email), '')) is null
    ),

    'acompanhantes_lista', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', c.nome, 'parentesco', c.parentesco, 'de', a.nome)
               order by a.nome, c.nome), '[]'::jsonb)
        from acompanhantes c join alunos a on a.id = c.aluno_id
    )
  );
end;
$$;

-- ------------------------------------------------------------
-- Só para quem está autenticado. A checagem de papel é dentro da
-- função — um avaliador logado que chamar isto recebe
-- 'sem_permissao', não a lista.
-- ------------------------------------------------------------
revoke execute on function public.exigir_gestor()  from public, anon;
revoke execute on function public.painel_gestor()  from public, anon;
grant  execute on function public.painel_gestor()  to authenticated;

-- ------------------------------------------------------------
-- DAR ACESSO A ALGUÉM
--
-- Quem já é avaliador vira gestor com:
--
--   update public.avaliadores set papel = 'gestor'
--    where email = 'direcao@exemplo.edu.br';
--
-- Quem ainda não existe precisa primeiro do usuário no auth —
-- Enable signup está OFF, ninguém se cadastra sozinho. Use o
-- scripts/criar-avaliadores.mjs com um CSV de uma linha e depois
-- rode o update acima.
--
-- Conferir quem tem acesso:
--
--   select nome, email, papel from public.avaliadores order by papel, nome;
--
-- Tirar o acesso:
--
--   update public.avaliadores set papel = 'avaliador' where email = '...';
-- ------------------------------------------------------------
