-- ============================================================
-- 0023 — Onde a falha de envio fica registrada
--
-- A 0022 fez o lote sobreviver a um endereço ruim, mas o motivo
-- da falha morria no histórico de execuções do n8n — que ninguém
-- abre, e que rotaciona.
--
-- O contador de tentativas diz QUE falhou. Esta migration guarda
-- POR QUE, ao lado da própria inscrição, onde quem revisa vai
-- procurar.
--
-- A diferença prática: "5 tentativas, endereço parece ok" manda
-- alguém investigar às cegas. "Invalid To header" diz para olhar
-- o endereço; "quota exceeded" diz que o problema é o limite do
-- Gmail e o endereço está certo.
-- ============================================================

alter table public.alunos
  add column if not exists email_erro    text,
  add column if not exists email_erro_em timestamptz;

comment on column public.alunos.email_erro is
  'Última recusa do servidor de e-mail, como ele respondeu. '
  'Preenchida pelo n8n pela saída de erro do nó de envio. '
  'Limpa sozinha quando o envio dá certo.';

-- ------------------------------------------------------------
-- registrar_falha_email(token, id, erro)
--
-- Só anota. NÃO marca como enviado e NÃO conta tentativa — quem
-- conta é a emails_pendentes, na próxima busca. Assim a linha
-- continua na fila e o registro não altera o fluxo.
--
-- O texto é cortado em 500 caracteres: rastro de pilha do n8n
-- pode vir com quilobytes, e o que interessa está no começo.
-- ------------------------------------------------------------
create or replace function public.registrar_falha_email(
  p_token text,
  p_id    uuid,
  p_erro  text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ok boolean;
begin
  select valor = p_token into v_ok
    from segredos where chave = 'token_n8n';

  if not coalesce(v_ok, false) then
    raise exception 'token_invalido';
  end if;

  update alunos
     set email_erro    = left(coalesce(nullif(trim(p_erro), ''), 'falha sem descrição'), 500),
         email_erro_em = now()
   where id = p_id;

  return jsonb_build_object('ok', found);
end;
$$;

-- Envio que dá certo apaga o erro antigo: linha com e-mail
-- entregue e erro registrado confunde quem lê depois.
create or replace function public.marcar_email_enviado(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ok boolean;
begin
  select valor = p_token into v_ok
    from segredos where chave = 'token_n8n';

  if not coalesce(v_ok, false) then
    raise exception 'token_invalido';
  end if;

  update alunos
     set email_confirmacao_em = now(),
         email_tentativas = 0,
         email_erro = null,
         email_erro_em = null
   where id = p_id and email_confirmacao_em is null;

  return jsonb_build_object('ok', found);
end;
$$;

revoke execute on function public.registrar_falha_email(text, uuid, text) from public;
grant  execute on function public.registrar_falha_email(text, uuid, text) to anon, authenticated;

-- ------------------------------------------------------------
-- painel_gestor: a falha aparece na lista
--
-- Recriada da 0020 com dois campos a mais por inscrição. É onde
-- você já olha para acompanhar — não faz sentido ter que abrir o
-- SQL Editor para descobrir que um e-mail não saiu.
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
                   'onde',        coalesce(a.colegio, a.unidade),
                   'ano',         a.ano_escolaridade,
                   'responsavel', a.responsavel_nome,
                   'contato',     coalesce(a.responsavel_email, a.email),
                   'acompanhantes', (select count(*) from acompanhantes c where c.aluno_id = a.id),
                   'ativo',       a.ativo,
                   'email_enviado', a.email_confirmacao_em is not null,
                   'email_erro',    a.email_erro,
                   'email_tentativas', a.email_tentativas,
                   'criado_em',   a.criado_em
                 ) as linha
            from alunos a
           order by a.criado_em desc
           limit 500
        ) q
    ),

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

    'sem_contato', (
      select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'tipo', tipo)
                                order by nome), '[]'::jsonb)
        from alunos
       where coalesce(nullif(trim(responsavel_email), ''), nullif(trim(email), '')) is null
    ),

    -- Quem não vai receber sem alguém intervir: endereço fora do
    -- formato, ou já aposentado por tentativas.
    'email_travado', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'nome', nome, 'tipo', tipo,
               'destino', coalesce(responsavel_email, email),
               'tentativas', email_tentativas,
               'erro', email_erro)
               order by criado_em), '[]'::jsonb)
        from alunos
       where email_confirmacao_em is null
         and (email_tentativas >= 5
              or email_erro is not null
              or coalesce(case when tipo = 'aluno' then responsavel_email else email end, '')
                 !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$')
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

revoke execute on function public.painel_gestor() from public, anon;
grant  execute on function public.painel_gestor() to authenticated;

-- ------------------------------------------------------------
-- COMO LIGAR NO n8n
--
-- No nó "Enviar e-mail", Settings > On Error >
-- "Continue (using error output)". Aparece uma segunda saída,
-- vermelha, embaixo da normal.
--
-- Ligue essa saída vermelha num HTTP Request novo:
--
--   Method: POST
--   URL:    https://SEU-PROJETO.supabase.co
--             /rest/v1/rpc/registrar_falha_email
--   Headers: apikey = <a chave anon>
--   Body (JSON):
--     {
--       "p_token": "<o token do n8n>",
--       "p_id": "{{ $('Montar e-mail').item.json.id }}",
--       "p_erro": "{{ $json.error?.message || JSON.stringify($json) }}"
--     }
--
-- A saída normal (branca) continua indo para "Marcar como
-- enviado". As duas nunca se cruzam: quem falha não é marcado
-- como enviado, e quem é enviado não registra erro.
-- ------------------------------------------------------------
