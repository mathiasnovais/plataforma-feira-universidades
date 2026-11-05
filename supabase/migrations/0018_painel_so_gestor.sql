-- ============================================================
-- 0018 — O painel inteiro passa a exigir login
--
-- A 0016 abriu painel_publico() para `anon`, com a ideia de que
-- contagem não identifica ninguém e por isso poderia ficar num
-- link aberto. A direção decidiu diferente: nem os números.
--
-- É uma decisão defensável e mais segura. "47 alunos da Barra
-- Américas" não identifica pessoa, mas é informação institucional
-- — quantas famílias aderiram, qual unidade engajou menos — e
-- isso não precisa estar ao alcance de quem tropeçar no endereço.
--
-- A função continua existindo: painel_gestor() a chama por
-- dentro para montar os números. Como painel_gestor() é SECURITY
-- DEFINER, ela roda como dona e não depende do grant de anon.
-- Revogar aqui não quebra nada.
-- ============================================================

revoke execute on function public.painel_publico() from public, anon, authenticated;

comment on function public.painel_publico() is
  'Contagens sem dado pessoal. NÃO é chamada diretamente por '
  'ninguém: existe para painel_gestor() reaproveitar. Se um dia '
  'voltar a existir um painel aberto, é ela que se concede de '
  'novo a anon — e aí revise o que ela devolve antes.';

-- ------------------------------------------------------------
-- Conferir depois de rodar
--
--   -- anon deve executar só o que o formulário precisa
--   select p.proname
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and has_function_privilege('anon', p.oid, 'execute')
--    order by 1;
--
--   Esperado: inscrever_aluno, inscrever_counselor, ping,
--   emails_pendentes, marcar_email_enviado.
--   painel_publico e painel_gestor NÃO podem aparecer.
--
--   -- e o painel continua funcionando para gestor
--   select public.painel_gestor();
--   (roda como você no SQL Editor, então dá 'nao_autenticado' —
--    isso é o esperado; o teste de verdade é abrir a página.)
-- ------------------------------------------------------------
