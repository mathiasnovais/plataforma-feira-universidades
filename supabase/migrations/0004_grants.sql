-- ============================================================
-- 0004 — Enxugar os grants padrão do Supabase
--
-- O Supabase concede os 7 privilégios de tabela a `anon` e
-- `authenticated` em tudo que nasce no schema `public`. A RLS
-- das migrations 0002/0003 já barra leitura e escrita indevida,
-- com uma exceção importante:
--
--   TRUNCATE não passa por RLS. É a única operação que ignora
--   as policies por completo.
--
-- Não é alcançável pelo PostgREST (não há verbo HTTP para
-- TRUNCATE), então não é buraco explorável hoje. Mas é
-- privilégio concedido sem razão sobre a tabela que guarda o
-- trabalho do dia inteiro. Mesmo raciocínio para REFERENCES e
-- TRIGGER.
--
-- Fica só o mínimo que as policies existentes precisam.
-- ============================================================

revoke all on public.avaliadores     from anon, authenticated;
revoke all on public.contatos_salvos from anon, authenticated;

-- `anon` não recebe nada: nenhuma tela funciona sem sessão.

-- Avaliador lê o próprio cadastro (policy avaliador_le_proprio).
grant select on public.avaliadores to authenticated;

-- Contatos: as 4 policies da 0002 continuam sendo a rota
-- alternativa ao RPC salvar_contato(), então os 4 verbos ficam.
grant select, insert, update, delete on public.contatos_salvos to authenticated;

-- ------------------------------------------------------------
-- Atenção para tabelas futuras
--
-- Isto corrige as tabelas que já existem. O Supabase mantém um
-- ALTER DEFAULT PRIVILEGES que dá os 7 privilégios a anon e
-- authenticated em QUALQUER tabela nova do schema public. Toda
-- tabela criada daqui em diante precisa do próprio revoke.
-- ------------------------------------------------------------
