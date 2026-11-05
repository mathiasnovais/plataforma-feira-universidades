-- ============================================================
-- 0008 — log_acesso não pode impedir exclusão
--
-- A 0001 criou as FKs de `log_acesso` sem `on delete cascade`.
-- Consequência: apagar um aluno falha enquanto houver qualquer
-- registro de acesso a ele.
--
-- Isso não é inconveniência de teste. A seção 10 dos requisitos
-- trata o direito de exclusão como resolvido por um `delete` que
-- cascateia. Do jeito que estava, um pedido de exclusão feito
-- pelo responsável de um menor não teria como ser atendido sem
-- alguém apagar o log à mão antes — e apagar log à mão durante
-- um pedido de exclusão é exatamente o tipo de operação que não
-- deve depender de memória humana.
--
-- Cascatear está correto aqui: `log_acesso` também é dado pessoal
-- (quem viu quem, e quando). Ele entra no mesmo prazo de retenção
-- e deve sair junto no expurgo.
-- ============================================================

alter table public.log_acesso
  drop constraint if exists log_acesso_aluno_id_fkey;

alter table public.log_acesso
  add constraint log_acesso_aluno_id_fkey
    foreign key (aluno_id) references public.alunos(id)
    on delete cascade;

alter table public.log_acesso
  drop constraint if exists log_acesso_avaliador_id_fkey;

alter table public.log_acesso
  add constraint log_acesso_avaliador_id_fkey
    foreign key (avaliador_id) references public.avaliadores(id)
    on delete cascade;

-- ------------------------------------------------------------
-- Conferência: as quatro FKs que apontam para dado pessoal
-- precisam estar em CASCADE.
--
--   contatos_salvos.aluno_id      -> alunos        (já era)
--   contatos_salvos.avaliador_id  -> avaliadores   (já era)
--   log_acesso.aluno_id           -> alunos        (esta migration)
--   log_acesso.avaliador_id       -> avaliadores   (esta migration)
-- ------------------------------------------------------------
-- select c.conname,
--        c.confdeltype = 'c' as cascateia
--   from pg_constraint c
--   join pg_class t on t.oid = c.conrelid
--  where c.contype = 'f'
--    and t.relname in ('log_acesso', 'contatos_salvos');
