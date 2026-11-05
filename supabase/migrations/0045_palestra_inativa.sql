-- ============================================================
-- 0045 — A lista de presença não pode sumir quando a palestra
--        para de aceitar inscrição
--
-- A 0044 filtrava as palestras por `ativa`. Parecia certo, e é o
-- filtro que a página pública usa — lá faz sentido: palestra
-- fechada não deve aparecer para quem vai se inscrever.
--
-- Só que a 0037 documenta, no próprio rodapé (linhas 221-222),
-- que o jeito de parar de aceitar inscrição sem perder quem já
-- entrou é:
--
--   update public.palestras set ativa = false where codigo = ...;
--
-- Ou seja: o comando que a organização vai rodar no dia do evento,
-- justamente quando a palestra começa, é o mesmo que faria a lista
-- de presença ficar vazia — com a coordenação em pé na porta da
-- sala e os inscritos entrando.
--
-- Agora a palestra entra na lista se estiver ativa OU se tiver
-- alguém inscrito. Fechar para novas inscrições deixa de ter
-- qualquer efeito sobre conferir quem chegou.
--
-- Nada mais muda: mesmo corpo da 0044, uma linha trocada.
-- ============================================================

create or replace function public.lista_presenca_palestras()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_palestras();
begin
  return jsonb_build_object(
    'gerado_em', now(),
    'palestras', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'codigo',    p.codigo,
                 'titulo',    p.titulo,
                 'palestrante', p.palestrante,
                 'vagas',     p.vagas,
                 'inscritos', (select count(*) from palestra_inscricoes i
                                where i.palestra_codigo = p.codigo),
                 'presentes', (select count(*) from palestra_inscricoes i
                                where i.palestra_codigo = p.codigo and i.presente),
                 'pessoas',   coalesce((
                   select jsonb_agg(
                            jsonb_build_object(
                              'id',       i.id,
                              'nome',     i.nome,
                              'presente', i.presente)
                            order by public.chave_nome(i.nome))
                     from palestra_inscricoes i
                    where i.palestra_codigo = p.codigo
                 ), '[]'::jsonb))
               order by p.ordem)
        from palestras p
       /* Não é só `p.ativa`. A receita da 0037 para parar de
          aceitar inscrição no dia é justamente marcar a palestra
          como inativa — e era exatamente aí que esta lista ficava
          vazia, com quem confere em pé na porta da sala. */
       where p.ativa
          or exists (select 1 from palestra_inscricoes i where i.palestra_codigo = p.codigo)
    ), '[]'::jsonb));
end;
$$;
