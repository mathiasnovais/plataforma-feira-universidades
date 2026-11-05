-- ============================================================
-- DADOS DE TESTE — feira de universidades
-- Rodar DEPOIS das migrations 0005, 0006 e 0007.
--
-- 5 alunos cobrindo as combinações de autorização que o
-- formulário permite. O expurgo está no fim do arquivo.
-- ============================================================

delete from public.alunos where nome like 'TESTE %';

insert into public.alunos
  (nome, email,
   aluno_alfacem, colegio, unidade, segmento, ano_escolaridade,
   responsavel_acompanha, parentesco,
   paises_interesse, motivo, experiencia_internacional, conhece_pathway,
   nivel_compartilhamento,
   consentimento_responsavel, consentimento_versao, consentimento_em,
   responsavel_nome, responsavel_email, responsavel_telefone,
   compartilhar_responsavel,
   ativo)
values

  -- 1) Autorizou tudo. O representante vê o perfil completo.
  ('TESTE Ana Ribeiro', 'ana.teste@exemplo.com',
   true, null, 'Barra Américas', 'Ensino Médio', '3ª Série do Ensino Médio',
   'Meu responsável irá me acompanhar', 'Mãe',
   array['Estados Unidos','Canadá'],
   'Tenho Interesse em aplicar para uma universidade no exterior',
   'Sim, já fiz um programa de intercâmbio', 'Sim',
   3, true, 'v1-2026', now(),
   'Beatriz Ribeiro', 'beatriz.teste@exemplo.com', '(21) 90000-0001',
   true, true),

  -- 2) Aluno autorizou, responsável não. Sem bloco do responsável.
  ('TESTE Bruno Costa', 'bruno.teste@exemplo.com',
   true, null, 'Freguesia - Jacarepaguá', 'Ensino Médio', '2ª Série do Ensino Médio',
   'Sozinho', 'Pai',
   array['Portugal','Itália'],
   'Conheço um pouco sobre o assunto, mas não tenho interesse de aplicar para uma universidade no exterior',
   'Sim, já viajei para fora a passeio', 'Já ouvi falar, mas não entendo o que é',
   3, true, 'v1-2026', now(),
   'Carlos Costa', 'carlos.teste@exemplo.com', '(21) 90000-0002',
   false, true),

  -- 3) Ninguém autorizou. Só o nome, Salvar desabilitado.
  ('TESTE Carla Dias', 'carla.teste@exemplo.com',
   false, 'Colégio Externo', null, 'Ensino Fundamental Anos Finais', '9º ano do Ensino Fundamental',
   'Meu responsável irá me acompanhar', 'Avó / Avô',
   array['Reino Unido'],
   'Não conheço nada sobre o assunto de aplicação internacional e quero entender',
   'Não, nunca saí do Brasil', 'Não',
   0, true, 'v1-2026', now(),
   'Dulce Dias', 'dulce.teste@exemplo.com', '(21) 90000-0003',
   false, true),

  -- 4) O caso perigoso: nível 3 na coluna, SEM consentimento do
  --    responsável. Simula erro de importação. Tem que se
  --    comportar como nível 0. Se mostrar e-mail, a trava quebrou.
  ('TESTE Diego Alves', 'diego.teste@exemplo.com',
   true, null, 'Barra Olímpica', 'Ensino Médio', '1ª Série do Ensino Médio',
   'Sozinho', 'Mãe',
   array['Alemanha','França'],
   'Tenho Interesse em aplicar para uma universidade no exterior',
   'Sim, já morei fora com a minha família', 'Sim',
   3, false, null, null,
   'Elaine Alves', 'elaine.teste@exemplo.com', '(21) 90000-0004',
   true, true),

  -- 5) Aluno NÃO autorizou, responsável SIM. Combinação real do
  --    formulário: Salvar habilitado, contato é o do responsável,
  --    interesses ocultos porque seguem a autorização do aluno.
  ('TESTE Elisa Moraes', 'elisa.teste@exemplo.com',
   true, null, 'Recreio', 'Ensino Médio', '2ª Série do Ensino Médio',
   'Meu responsável irá me acompanhar', 'Mãe',
   array['Canadá'],
   'Tenho Interesse em aplicar para uma universidade no exterior',
   'Não, nunca saí do Brasil', 'Já ouvi falar, mas não entendo o que é',
   0, true, 'v1-2026', now(),
   'Marta Moraes', 'marta.teste@exemplo.com', '(21) 90000-0005',
   true, true);


-- ------------------------------------------------------------
-- Códigos para digitar na entrada manual do app
-- ------------------------------------------------------------
select nome,
       nivel_compartilhamento   as nivel_aluno,
       compartilhar_responsavel as resp,
       consentimento_responsavel as consentiu,
       codigo_curto
  from public.alunos
 where nome like 'TESTE %'
 order by nome;


-- ------------------------------------------------------------
-- O que esperar no app
--
--   Ana    -> perfil completo: escola, ano, países, e-mail, responsável
--   Bruno  -> perfil completo, SEM bloco do responsável
--   Carla  -> só o nome, Salvar desabilitado
--   Diego  -> igual à Carla, apesar de estar nível 3 no banco
--   Elisa  -> nome + contato do responsável, Salvar HABILITADO,
--             sem países nem ano
-- ------------------------------------------------------------


-- ------------------------------------------------------------
-- Seu usuário de avaliador
-- Crie antes em Authentication > Users > Add user (Auto Confirm).
-- ------------------------------------------------------------
insert into public.avaliadores (id, nome, email, organizacao)
select u.id, 'Mathias Novais', u.email, 'Organização do evento'
  from auth.users u
 where u.email = 'usuario1@exemplo.edu.br'
on conflict (id) do nothing;

select a.email, a.nome, u.email_confirmed_at is not null as pode_logar
  from public.avaliadores a
  join auth.users u on u.id = a.id;


-- ============================================================
-- EXPURGO — rodar antes de importar os alunos de verdade
-- ============================================================
-- delete from public.alunos where nome like 'TESTE %';
