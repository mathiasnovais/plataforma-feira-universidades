-- ============================================================
-- 0034 — Prazo de inscrição de aluno da Rede, no formulário
--
-- As inscrições de aluno da Rede pelo site fecham em 19/08/2026
-- às 23:59. Depois disso o formulário deixa de oferecer a opção
-- "Aluno da Rede" — e, junto com ela, os acompanhantes desse
-- aluno, que só existem dentro da mesma inscrição.
--
-- O BLOQUEIO É SÓ DA TELA. DE PROPÓSITO.
--
-- Nada aqui recusa inscrição no banco. Chegou a ser escrito um
-- gatilho que barrava aluno interno depois do prazo, e ele foi
-- descartado: no dia do evento a organização precisa inscrever
-- aluno interno pelo balcão e pelo QR do cartaz, e um gatilho que
-- distinguisse esses caminhos por heurística seria uma trava com
-- chance de fechar a porta errada, no pior dia possível.
--
-- O prazo é um combinado com as famílias, não uma regra de
-- segurança. Tirar a opção da tela cumpre o combinado; o que
-- entra pelas outras portas continua entrando.
--
-- O QUE ESTA MIGRATION FAZ
--
-- Guarda a data e devolve, para quem perguntar, se já passou. O
-- formulário pergunta ao abrir, em vez de olhar o relógio do
-- celular de quem preenche: aparelho com data adiantada
-- bloquearia uma família antes da hora, e com data atrasada
-- deixaria preencher cinco etapas para nada.
-- ============================================================

insert into public.segredos (chave, valor)
values ('prazo_aluno_rede', '2026-08-19T23:59:59-03:00')
on conflict (chave) do update set valor = excluded.valor;

comment on table public.segredos is
  'Configuração e segredos do sistema. prazo_aluno_rede é o fim '
  'das inscrições de aluno interno pelo formulário do site, em '
  'ISO 8601 com fuso. Apagar a linha reabre o formulário.';

-- ------------------------------------------------------------
-- prazo_inscricao_rede(): pública, e não revela nada
--
-- Devolve a data do prazo — a mesma que já está impressa no
-- cabeçalho do formulário — e a hora do servidor. Nada que o
-- cartaz na parede não diga.
-- ------------------------------------------------------------
create or replace function public.prazo_inscricao_rede()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'prazo',     (select valor from segredos where chave = 'prazo_aluno_rede'),
    'agora',     now(),
    -- Sem prazo configurado, nunca está encerrado: apagar a linha
    -- de `segredos` é o jeito de reabrir sem mexer em código.
    'encerrado', coalesce(
                   now() > (select valor::timestamptz from segredos
                             where chave = 'prazo_aluno_rede'),
                   false)
  );
$$;

revoke execute on function public.prazo_inscricao_rede() from public;
grant  execute on function public.prazo_inscricao_rede() to anon, authenticated;

-- ------------------------------------------------------------
-- MUDAR, CONFERIR OU REABRIR
--
-- Adiar:
--   update public.segredos set valor = '2026-08-21T23:59:59-03:00'
--    where chave = 'prazo_aluno_rede';
--
-- Reabrir:
--   delete from public.segredos where chave = 'prazo_aluno_rede';
--
-- Ver como está agora:
--   select public.prazo_inscricao_rede();
--
-- As três valem NA HORA, sem republicar o site: a página pergunta
-- a cada vez que alguém a abre.
-- ------------------------------------------------------------
