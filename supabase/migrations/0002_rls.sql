-- ============================================================
-- 0002 — Row Level Security
-- Referência: requisitos-plataforma-avaliadores.md, seções 7.1 e 7.2
-- ============================================================

alter table public.avaliadores     enable row level security;
alter table public.alunos          enable row level security;
alter table public.contatos_salvos enable row level security;
alter table public.log_acesso      enable row level security;

-- `alunos` e `log_acesso` ficam DE PROPÓSITO sem nenhuma policy.
-- RLS ativo + zero policies = ninguém lê direto, nem o avaliador
-- logado. Todo acesso passa pelas funções SECURITY DEFINER da
-- migration 0003.
--
-- Se algum dia alguém criar uma policy de select em `alunos`,
-- vaza telefone de menor de idade. Não crie.

-- Segunda camada: o Supabase concede por padrão todos os
-- privilégios de tabela do schema `public` a anon e authenticated.
-- Com RLS sem policy isso já não lê nada — mas se alguém criar
-- uma policy por engano no meio do evento, o grant estaria de pé
-- esperando. Tirando o grant, o engano não basta para vazar.
-- As funções SECURITY DEFINER rodam como owner e não são afetadas.
revoke all on public.alunos     from anon, authenticated;
revoke all on public.log_acesso from anon, authenticated;

-- ------------------------------------------------------------
-- Avaliador lê apenas o próprio cadastro
-- ------------------------------------------------------------
create policy "avaliador_le_proprio" on public.avaliadores
  for select to authenticated
  using (id = auth.uid());

-- ------------------------------------------------------------
-- Avaliador gerencia apenas os próprios contatos
--
-- O caminho normal de escrita é o RPC salvar_contato(), mas as
-- policies de insert/update ficam de pé como rota alternativa
-- (e porque a PK composta já garante que ninguém escreve em
-- nome de outro avaliador).
-- ------------------------------------------------------------
create policy "contatos_select" on public.contatos_salvos
  for select to authenticated
  using (avaliador_id = auth.uid());

create policy "contatos_insert" on public.contatos_salvos
  for insert to authenticated
  with check (avaliador_id = auth.uid());

create policy "contatos_update" on public.contatos_salvos
  for update to authenticated
  using (avaliador_id = auth.uid())
  with check (avaliador_id = auth.uid());

create policy "contatos_delete" on public.contatos_salvos
  for delete to authenticated
  using (avaliador_id = auth.uid());
