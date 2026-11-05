-- ============================================================
-- 0022 — Um e-mail ruim não segura mais a fila
--
-- O QUE ACONTECEU
--
-- Uma família digitou "@gmail.c". O endereço passou pela
-- validação da 0021 — que exigia só "ponto seguido de algo" —,
-- o Gmail recusou, e a execução do n8n abortou. Os 49 e-mails
-- que vinham DEPOIS dele na fila não foram tentados.
--
-- Pior: como a fila sempre devolve na mesma ordem, a execução
-- seguinte parava exatamente no mesmo ponto. Um erro de digitação
-- de uma pessoa travou a confirmação de todas as outras, por
-- tempo indeterminado, sem ninguém perceber.
--
-- DUAS CORREÇÕES, E A SEGUNDA É A QUE IMPORTA
--
-- 1. Validação mais firme: TLD com duas letras ou mais. Pega o
--    "@gmail.c" e os parentes dele.
--
--    Mas isso é remendo. Nenhum regex prevê "@gmial.com", que é
--    válido em formato e inexistente na prática. Sempre vai
--    existir um endereço que só o servidor de e-mail sabe
--    recusar.
--
-- 2. Contador de tentativas, para desistir de quem não tem
--    conserto. Depois de 5 idas à fila sem confirmação, a linha
--    sai do caminho das outras e fica registrada na consulta do
--    rodapé, para alguém olhar.
--
-- O QUE ESTA MIGRATION *NÃO* RESOLVE
--
-- Chegamos a pensar que ordenar por tentativas faria a linha
-- ruim ir para o fim sozinha. Não faz: todas as linhas do lote
-- contam tentativa juntas, então a ruim continua empatada com as
-- outras e volta para a mesma posição. Simulado e reprovado.
--
-- Quem impede um endereço de travar o lote é o n8n, e isso é
-- responsabilidade dele mesmo: o nó de e-mail precisa estar em
--
--   Settings > On Error > "Continue (using error output)"
--
-- com a saída de erro DESCONECTADA. Aí o item que falha não
-- chega ao "Marcar como enviado", continua pendente, conta
-- tentativa na próxima passada, e os outros seguem normalmente.
--
-- Não é contorno: é como o n8n expressa "esta etapa pode falhar
-- em um item sem invalidar os demais". O contador desta migration
-- é o que fecha o ciclo, aposentando quem falha sempre.
-- ============================================================

alter table public.alunos
  add column if not exists email_tentativas integer not null default 0;

comment on column public.alunos.email_tentativas is
  'Quantas vezes esta linha foi entregue ao n8n para envio. '
  'Sobe a cada busca na fila, não a cada sucesso. Serve para '
  'empurrar endereço problemático para o fim e, depois de 5, '
  'tirá-lo do caminho dos demais.';

create index if not exists alunos_email_fila_idx
  on public.alunos (email_tentativas, criado_em)
  where email_confirmacao_em is null;

-- ------------------------------------------------------------
-- emails_pendentes: conta a tentativa e ordena por ela
-- ------------------------------------------------------------
create or replace function public.emails_pendentes(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ok  boolean;
  v_ids uuid[];
begin
  select valor = p_token into v_ok
    from segredos where chave = 'token_n8n';

  if not coalesce(v_ok, false) then
    raise exception 'token_invalido';
  end if;

  -- Quem entra neste lote. Menos tentativas primeiro: linha que
  -- nunca foi tentada tem prioridade sobre a que já falhou.
  select array_agg(id) into v_ids
    from (
      select a.id
        from alunos a
       where a.email_confirmacao_em is null
         and a.email_tentativas < 5
         and coalesce(case when a.tipo = 'aluno' then a.responsavel_email else a.email end, '')
             ~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$'
       order by a.email_tentativas, a.criado_em
       limit 50
    ) q;

  if v_ids is null then
    return '[]'::jsonb;
  end if;

  -- Conta a tentativa ANTES de entregar. Se o n8n morrer no meio,
  -- a linha reaparece no próximo lote, uma posição atrás — que é
  -- o comportamento desejado para algo que pode estar quebrado.
  update alunos set email_tentativas = email_tentativas + 1
   where id = any(v_ids);

  return coalesce((
    select jsonb_agg(linha order by linha->>'criado_em')
      from (
        select jsonb_build_object(
                 'id',         a.id,
                 'tipo',       a.tipo,
                 'nome',       a.nome,
                 'destino',    case when a.tipo = 'aluno'
                                    then a.responsavel_email
                                    else a.email end,
                 'destinatario', case when a.tipo = 'aluno'
                                      then a.responsavel_nome
                                      else a.nome end,
                 'aluno',      case when a.tipo = 'aluno' then a.nome end,
                 'instituicao', coalesce(a.colegio, a.unidade),
                 'ano',        a.ano_escolaridade,
                 'acompanhantes', coalesce((
                    select jsonb_agg(c.nome order by c.nome)
                      from acompanhantes c where c.aluno_id = a.id), '[]'::jsonb),
                 'protocolo',  upper(substr(replace(a.id::text, '-', ''), 1, 8)),
                 'criado_em',  a.criado_em
               ) as linha
          from alunos a
         where a.id = any(v_ids)
      ) q
  ), '[]'::jsonb);
end;
$$;

-- Envio bem-sucedido zera o contador junto com a marcação: se
-- alguém pedir reenvio depois, a linha volta com prioridade
-- normal em vez de já entrar penalizada.
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
         email_tentativas = 0
   where id = p_id and email_confirmacao_em is null;

  return jsonb_build_object('ok', found);
end;
$$;

revoke execute on function public.emails_pendentes(text)           from public;
revoke execute on function public.marcar_email_enviado(text, uuid) from public;
grant  execute on function public.emails_pendentes(text)           to anon, authenticated;
grant  execute on function public.marcar_email_enviado(text, uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- QUEM FICOU PARA TRÁS
--
-- Rode uma vez por semana até o evento. Lista quem não vai
-- receber confirmação sem intervenção humana — endereço fora do
-- formato, ou que falhou 5 vezes.
--
--   select tipo, nome,
--          case when tipo = 'aluno' then responsavel_nome else nome end as quem_informou,
--          case when tipo = 'aluno' then responsavel_email else email end as destino,
--          email_tentativas, criado_em
--     from public.alunos
--    where email_confirmacao_em is null
--      and (email_tentativas >= 5
--           or coalesce(case when tipo = 'aluno' then responsavel_email else email end, '')
--              !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$')
--    order by criado_em;
--
-- Depois de corrigir um endereço, devolva a pessoa à fila:
--
--   update public.alunos
--      set responsavel_email = 'certo@email.com', email_tentativas = 0
--    where id = 'cole-o-id-aqui';
--
-- CORREÇÃO DO CASO QUE APARECEU
--
--   update public.alunos
--      set responsavel_email = replace(responsavel_email, '@gmail.c', '@gmail.com'),
--          email_tentativas = 0
--    where responsavel_email like '%@gmail.c';
-- ------------------------------------------------------------
