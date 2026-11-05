-- ============================================================
-- 0054 — Uma tela só para a direção ler as duas pesquisas
--
-- Hoje o resultado só sai por script, na mão de quem tem a
-- service_role. Isso é bom para gerar planilha e péssimo para
-- responder "e aí, como foi?" numa reunião: obriga a passar a
-- chave que ignora toda a RLS para quem só queria ver uma média.
--
-- Esta função devolve as duas pesquisas de uma vez, para quem tem
-- papel de diretoria, com a chave `anon` do navegador. Nenhuma
-- service_role sai do lugar.
--
-- POR QUE DEVOLVE AS LINHAS, E NÃO SÓ AS MÉDIAS
--
-- Calcular tudo em SQL renderia um jsonb enorme e engessado: a
-- primeira pergunta que alguém faz depois de ver a média é "quantos
-- deram nota 1?", e aí seria migration nova.
--
-- As respostas são anônimas por construção (0051 e 0053) — não há
-- coluna que aponte para pessoa nenhuma. Então mandar as linhas
-- cruas não vaza nada, e a tela faz a conta que quiser. São
-- dezenas de linhas, não milhares.
--
-- O QUE NÃO VAI JUNTO
--
-- Nomes. Nem os das universidades, nem os das famílias. A pesquisa
-- prometeu anonimato nas duas línguas e a promessa vale também
-- para quem está do lado de dentro.
--
-- Sai, sim, a CONTAGEM de quantos representantes já responderam,
-- que vem da marca em `avaliadores` e não aponta para resposta
-- nenhuma — a mesma separação de urna da 0051.
-- ============================================================

create or replace function public.painel_respostas()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_diretoria();
begin
  return jsonb_build_object(
    'agora', now(),

    -- ---- pesquisa das universidades (0049 / 0051 / 0052) ----
    'universidades', jsonb_build_object(
      'codigo',  (select codigo from pesquisa_evento limit 1),
      'aberta',  coalesce((select aberta from pesquisa_evento limit 1), false),

      -- Quantos poderiam responder: representante de universidade
      -- que esteve na feira. Cobrar de quem não foi não faz sentido.
      'convidados', (
        select count(*) from avaliadores av
         where av.papel = 'avaliador'
           and (av.presente
                or exists (select 1 from log_acesso l where l.avaliador_id = av.id))),

      -- Quantos usaram o link PESSOAL. Quem responde pelo link geral
      -- não é marcado, e por isso o total de respostas pode passar
      -- deste número — não é erro, é o anonimato funcionando.
      'marcados', (select count(*) from avaliadores where respondeu_pesquisa_em is not null),

      'respostas', coalesce(
        (select jsonb_agg(to_jsonb(a) - 'id') from avaliacoes_evento a), '[]'::jsonb)
    ),

    -- ---- pesquisa das famílias (0053) ----
    'familias', jsonb_build_object(
      'codigo', (select codigo from pesquisa_familias limit 1),
      'aberta', coalesce((select aberta from pesquisa_familias limit 1), false),

      -- Quantos poderiam responder: alunos presentes mais os
      -- acompanhantes credenciados. É o denominador honesto da
      -- taxa de resposta.
      'convidados', (
        (select count(*) from alunos
          where ativo and coalesce(tipo, 'aluno') = 'aluno' and presente)
        +
        (select count(*) from acompanhantes where presente)),

      'respostas', coalesce(
        (select jsonb_agg(to_jsonb(f) - 'id' order by f.criado_em)
           from avaliacoes_familias f), '[]'::jsonb)
    )
  );
end;
$$;

revoke execute on function public.painel_respostas() from public, anon;
grant  execute on function public.painel_respostas() to authenticated;

comment on function public.painel_respostas() is
  'As duas pesquisas para a tela da direção. Só papel = diretoria. '
  'Não devolve nome de ninguém: as respostas são anônimas por '
  'construção e continuam anônimas aqui dentro.';

-- ------------------------------------------------------------
-- CONFERÊNCIA
--
-- `select public.painel_respostas()` no SQL Editor NÃO serve de
-- teste: exigir_diretoria() recusa antes de o corpo ser planejado,
-- porque ali não há sessão de usuário. Foi assim que a 0035 subiu
-- quebrada.
--
-- Para exercitar o SQL de dentro, rode as partes soltas:
--
--   select count(*) from public.avaliacoes_evento;
--   select count(*) from public.avaliacoes_familias;
--
--   select count(*) from public.avaliadores av
--    where av.papel = 'avaliador'
--      and (av.presente
--           or exists (select 1 from public.log_acesso l
--                       where l.avaliador_id = av.id));
--   -- nesta edição: 38
--
--   select (select count(*) from public.alunos
--            where ativo and coalesce(tipo,'aluno') = 'aluno' and presente)
--        + (select count(*) from public.acompanhantes where presente);
--   -- nesta edição: 332 + 266 = 598
--
-- O teste de verdade é abrir respostas.html com uma conta de
-- diretoria.
-- ------------------------------------------------------------
