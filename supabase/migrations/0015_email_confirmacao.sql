-- ============================================================
-- 0015 — E-mail de confirmação da inscrição
--
-- Quem preenche o formulário passa a ser avisado na tela de que
-- receberá um e-mail. Esta migration é o lado do banco desse
-- aviso: uma fila de envio que o n8n consome.
--
-- POR QUE FILA, E NÃO DISPARO NA HORA
--
-- A alternativa era o formulário chamar o webhook do n8n direto
-- do navegador, depois de gravar. Dois problemas:
--
--   1. O webhook ficaria público no código-fonte da página, e
--      qualquer um poderia usá-lo para mandar e-mail com o
--      remetente da escola.
--   2. Se o n8n estivesse fora do ar naquele segundo, o e-mail
--      se perderia sem deixar rastro — e ninguém descobriria
--      antes de a família ligar reclamando.
--
-- Com fila, o envio é reprocessável: a linha fica marcada como
-- pendente até alguém conseguir mandar. n8n fora do ar por duas
-- horas significa e-mail atrasado, não e-mail perdido.
--
-- AUTENTICAÇÃO SEM service_role
--
-- O n8n só precisa ler a fila e marcar como enviado, não a tabela
-- inteira. Duas RPCs com um token dedicado dão exatamente isso.
-- Guardar a service_role no n8n daria a ele poder de ler e apagar
-- todo o banco para fazer uma tarefa que envolve nome e e-mail.
-- ============================================================

alter table public.alunos
  add column if not exists email_confirmacao_em timestamptz;

comment on column public.alunos.email_confirmacao_em is
  'Quando o e-mail de confirmação foi enviado. NULL = na fila. '
  'Zerar esta coluna reenvia o e-mail na próxima passada do n8n.';

-- Índice parcial: a fila é sempre "o que ainda é null", e essa é
-- a minoria das linhas depois que o evento passa.
create index if not exists alunos_email_pendente_idx
  on public.alunos (criado_em)
  where email_confirmacao_em is null;

-- ------------------------------------------------------------
-- Token do n8n
--
-- Gerado aqui, uma vez. Leia-o UMA VEZ depois de rodar, cole na
-- credencial do n8n e não guarde em mais lugar nenhum:
--
--   select valor from public.segredos where chave = 'token_n8n';
--
-- Para trocar depois (se vazar, ou por rotina):
--
--   update public.segredos set valor = gen_random_uuid()::text
--    where chave = 'token_n8n';
-- ------------------------------------------------------------
insert into public.segredos (chave, valor)
values ('token_n8n', gen_random_uuid()::text)
on conflict (chave) do nothing;

-- ------------------------------------------------------------
-- emails_pendentes(token)
--
-- Devolve quem ainda não recebeu confirmação. Não marca nada:
-- marcar aqui perderia o e-mail se o n8n caísse entre o retorno
-- e o envio. Marcar depois, no marcar_email_enviado(), no pior
-- caso repete um e-mail — que é o erro barato dos dois.
--
-- Devolve independentemente de `ativo`: a confirmação é da
-- INSCRIÇÃO recebida, não da aprovação. A família precisa saber
-- que chegou, e a revisão acontece depois.
-- ------------------------------------------------------------
create or replace function public.emails_pendentes(p_token text)
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

  return coalesce((
    select jsonb_agg(linha order by linha->>'criado_em')
      from (
        select jsonb_build_object(
                 'id',         a.id,
                 'tipo',       a.tipo,
                 'nome',       a.nome,
                 -- Para quem o e-mail vai: a família responde pelo
                 -- responsável; o counselor responde por si.
                 'destino',    case when a.tipo = 'counselor'
                                    then a.email
                                    else a.responsavel_email end,
                 'destinatario', case when a.tipo = 'counselor'
                                      then a.nome
                                      else a.responsavel_nome end,
                 'aluno',      case when a.tipo = 'aluno' then a.nome end,
                 'instituicao', case when a.tipo = 'counselor'
                                     then a.colegio
                                     else coalesce(a.unidade, a.colegio) end,
                 'ano',        a.ano_escolaridade,
                 'acompanhantes', coalesce((
                    select jsonb_agg(c.nome order by c.nome)
                      from acompanhantes c where c.aluno_id = a.id), '[]'::jsonb),
                 'protocolo',  upper(substr(replace(a.id::text, '-', ''), 1, 8)),
                 'criado_em',  a.criado_em
               ) as linha
          from alunos a
         where a.email_confirmacao_em is null
           and coalesce(case when a.tipo = 'counselor' then a.email
                             else a.responsavel_email end, '') <> ''
         order by a.criado_em
         limit 50            -- lote: não estoura o SMTP num pico
      ) q
  ), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------------
-- marcar_email_enviado(token, id)
--
-- Um por vez, chamado logo depois de cada envio bem-sucedido. Se
-- o envio falhar, o n8n simplesmente não chama, e a linha volta
-- na próxima passada.
-- ------------------------------------------------------------
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

  update alunos set email_confirmacao_em = now()
   where id = p_id and email_confirmacao_em is null;

  return jsonb_build_object('ok', found);
end;
$$;

-- ------------------------------------------------------------
-- Grants
--
-- O n8n chama com a chave anon e prova quem é pelo token. As duas
-- funções são SECURITY DEFINER, então o token é a única barreira
-- — e é por isso que ele não pode ir para o navegador. NÃO use
-- estas RPCs no formulário.
-- ------------------------------------------------------------
revoke execute on function public.emails_pendentes(text)           from public;
revoke execute on function public.marcar_email_enviado(text, uuid) from public;
grant  execute on function public.emails_pendentes(text)           to anon, authenticated;
grant  execute on function public.marcar_email_enviado(text, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- Depois de rodar
--
-- 1. Pegue o token e cole no n8n:
--      select valor from public.segredos where chave = 'token_n8n';
--
-- 2. Veja a fila:
--      select count(*) from public.alunos where email_confirmacao_em is null;
--
-- 3. Teste a RPC (troque o token):
--      select public.emails_pendentes('cole-o-token-aqui');
--
-- AS INSCRIÇÕES QUE JÁ EXISTEM entram na fila, porque a coluna
-- nasce NULL. Se você não quiser reenviar para quem já se
-- inscreveu, marque tudo como enviado ANTES de ligar o n8n:
--
--      update public.alunos set email_confirmacao_em = now()
--       where email_confirmacao_em is null;
-- ------------------------------------------------------------
