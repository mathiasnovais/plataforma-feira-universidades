-- ============================================================
-- 0009 — ping() para manter o projeto acordado
--
-- Projeto no plano free do Supabase é pausado após alguns dias
-- sem atividade. Se o evento for daqui a semanas e ninguém tocar
-- no banco, ele pode estar dormindo na véspera.
--
-- Uma requisição que só bate no gateway pode não contar como
-- atividade de banco. Esta função executa dentro do Postgres,
-- então não há dúvida sobre o que conta.
--
-- Devolve só a hora do servidor. Não lê tabela nenhuma, não
-- recebe parâmetro, não tem como vazar coisa alguma — por isso
-- pode ser chamada com a chave `anon`, e o agendador do n8n não
-- precisa guardar a service_role para isso.
-- ============================================================

create or replace function public.ping()
returns timestamptz
language sql
volatile
as $$
  select now();
$$;

revoke execute on function public.ping() from public;
grant  execute on function public.ping() to anon, authenticated;

comment on function public.ping() is
  'Keep-alive do plano free. Chamada diária pelo workflow '
  'n8n/manter-supabase-ativo.json. Pode ser removida se o '
  'projeto migrar para Pro.';
