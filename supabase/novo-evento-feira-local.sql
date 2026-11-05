-- ============================================================
-- FEIRA LOCAL — limpeza dos dados da feira internacional
--
-- NÃO é migration e NÃO roda sozinho. É um roteiro para o SQL
-- Editor, para ser executado UMA vez, de propósito, quando a
-- direção decidir que os dados do evento anterior já cumpriram
-- seu papel.
--
-- ANTES DE RODAR, confira os três pontos:
--
--   1. Os leads já foram entregues às universidades
--      (scripts/leads-avaliadores.mjs) — depois daqui não há
--      como regenerar nada.
--   2. As pesquisas já foram exportadas, se interessam
--      (scripts em arquivo-internacional/scripts/).
--   3. O prazo de retenção prometido no termo de consentimento
--      permite (ou manda) apagar. Apagar é o destino previsto
--      desses dados; o que este roteiro faz é cumprir o termo.
--
-- O QUE APAGA: alunos, acompanhantes, contatos salvos, log de
-- acesso, palestras, pesquisas e as CONTAS dos representantes da
-- feira internacional (papel 'avaliador').
--
-- O QUE FICA: o schema inteiro, as funções, e as contas da
-- equipe (gestor, diretoria, supervisor, atendente) — vocês
-- continuam logando normalmente.
-- ============================================================

begin;

-- Pesquisas pós-evento (respostas são anônimas; somem junto).
truncate table public.avaliacoes_evento;
truncate table public.avaliacoes_familias;
truncate table public.pesquisa_familias;
truncate table public.pesquisa_evento;

-- Palestras e inscrições nelas (a feira local não as usa).
truncate table public.palestra_inscricoes;
truncate table public.palestras cascade;

-- Rastro anti-abuso da inscrição pública.
truncate table public.inscricao_tentativas;

-- O miolo: leads, log LGPD, famílias e alunos.
-- A ordem respeita as chaves estrangeiras.
delete from public.contatos_salvos;
delete from public.log_acesso;
delete from public.acompanhantes;
delete from public.alunos;

-- As contas dos representantes da feira internacional. Apagar em
-- auth.users leva junto a linha de public.avaliadores (FK com
-- cascade) e o que restasse de contatos deles. As 7 universidades
-- da feira local entram depois, novas, pela tela do evento.html
-- (Gestão de usuários) ou pelo scripts/criar-avaliadores.mjs.
delete from auth.users
 where id in (select id from public.avaliadores where papel = 'avaliador');

commit;

-- ------------------------------------------------------------
-- Conferência depois de rodar:
--
--   select 'alunos' t, count(*) from public.alunos
--   union all select 'acompanhantes', count(*) from public.acompanhantes
--   union all select 'contatos',      count(*) from public.contatos_salvos
--   union all select 'log',           count(*) from public.log_acesso;
--   -- tudo zero
--
--   select papel, count(*) from public.avaliadores group by papel;
--   -- só a equipe; nenhuma linha 'avaliador'
-- ------------------------------------------------------------
