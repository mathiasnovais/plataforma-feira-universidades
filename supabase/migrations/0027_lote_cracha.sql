-- ============================================================
-- 0027 — Levas de impressão de crachá
--
-- A aprovação não acontece de uma vez só. Aprova-se um grupo,
-- imprime-se, e dias depois chega mais gente que também precisa
-- ser aprovada e impressa.
--
-- Até aqui `gerar-crachas.mjs` lia todo mundo com `ativo = true`.
-- Na segunda geração ele traria de volta os 300 já impressos
-- junto com os 40 novos — e a única defesa era a organização
-- lembrar disso e recortar a mão (docs/inscricoes.md avisava
-- exatamente isso). Crachá duplicado no evento é pior do que
-- parece: dois papéis com o mesmo QR circulando, e a lista de
-- presença não sabe qual deles entrou.
--
-- `cracha_lote` é o carimbo de "este já saiu em papel". Nulo =
-- está na fila. Preenchido = imprimiu na leva N e não entra em
-- geração nenhuma daqui em diante, a não ser que peçam a leva N
-- de volta explicitamente.
--
-- Acompanhante não tem coluna própria: ele herda a leva do aluno,
-- porque o crachá dele carrega o token do aluno (0012) e os dois
-- são impressos e recortados juntos.
-- ============================================================

alter table public.alunos
  add column if not exists cracha_lote      integer,
  add column if not exists cracha_gerado_em timestamptz;

-- A fila é `cracha_lote is null`, e é a consulta que o script faz
-- toda vez. Índice parcial: só as linhas da fila entram nele, e a
-- fila esvazia conforme as levas saem.
create index if not exists alunos_fila_cracha_idx
  on public.alunos (criado_em)
  where cracha_lote is null;

comment on column public.alunos.cracha_lote is
  'Leva de impressão em que o crachá saiu. Nulo = ainda na fila. '
  'Preenchido pelo scripts/gerar-crachas.mjs no momento da geração.';

comment on column public.alunos.cracha_gerado_em is
  'Quando o arquivo daquela leva foi gerado. Só registro — quem '
  'decide se a pessoa entra numa nova geração é o cracha_lote.';

-- ------------------------------------------------------------
-- Já imprimiu antes desta migration?
--
-- Rode UMA VEZ, antes de gerar a próxima leva, para carimbar como
-- leva 1 quem já está com o crachá na mão. Sem isso essa gente
-- volta na primeira geração e sai em duplicata.
--
--   update public.alunos
--      set cracha_lote = 1, cracha_gerado_em = now()
--    where ativo and cracha_lote is null;
--
-- Se ninguém foi impresso ainda, não rode nada: a fila já está
-- correta com todo mundo nela.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- CONSULTAS DO DIA A DIA
--
-- Situação geral:
--
--   select coalesce(cracha_lote::text, 'na fila')  as leva,
--          count(*)                                 as pessoas,
--          min(cracha_gerado_em)                    as gerado_em
--     from public.alunos
--    where ativo
--    group by 1
--    order by 1;
--
-- Quem está esperando crachá agora:
--
--   select nome, coalesce(unidade, colegio) as onde, criado_em
--     from public.alunos
--    where ativo and cracha_lote is null
--    order by criado_em;
--
-- O que saiu numa leva específica (com os acompanhantes):
--
--   select a.nome, a.codigo_curto, c.nome as acompanhante
--     from public.alunos a
--     left join public.acompanhantes c on c.aluno_id = a.id
--    where a.cracha_lote = 2
--    order by a.nome, c.nome;
--
-- Desfazer uma leva — o arquivo foi gerado mas não foi impresso.
-- Devolve todo mundo para a fila:
--
--   update public.alunos
--      set cracha_lote = null, cracha_gerado_em = null
--    where cracha_lote = 2;
--
-- Devolver UMA pessoa para a fila (crachá saiu borrado, perdeu-se
-- antes de entregar):
--
--   update public.alunos
--      set cracha_lote = null, cracha_gerado_em = null
--    where codigo_curto = 'K7M2QX';
--
-- Atenção: reemitir crachá perdido DEPOIS de entregue é outra
-- coisa. Ali o token velho precisa morrer, senão o papel perdido
-- continua abrindo o perfil — veja docs/crachas.md.
-- ------------------------------------------------------------
