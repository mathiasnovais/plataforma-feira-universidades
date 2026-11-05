-- ============================================================
-- 0040 — Credenciamento dos representantes
--
-- O representante de universidade chega, recebe crachá e kit, e
-- vai para o estande. Até aqui isso não era registrado em lugar
-- nenhum: `avaliadores` tinha nome, e-mail, organização e papel,
-- e mais nada.
--
-- Sem isso, a mesa não sabe quem já passou — e no fim do dia
-- ninguém sabe quantos dos 45 convidados realmente vieram.
--
-- MESMO DESENHO DA PRESENÇA DE ALUNO (0025)
--
-- presente / presente_em / presente_por, com o gestor que marcou.
-- Três colunas iguais às de `alunos` e `acompanhantes`, porque a
-- pergunta é a mesma e não há razão para inventar outro formato.
--
-- UMA MARCA SÓ PARA CRACHÁ E KIT
--
-- Poderiam ser duas colunas — chegou, e recebeu o kit. Na mesa
-- são o mesmo gesto: a pessoa chega, confere o nome, leva as duas
-- coisas. Duas caixas seriam dois toques para registrar um evento
-- só, e a segunda ficaria esquecida na primeira hora cheia.
--
-- Se um dia o kit acabar e for preciso separar, a coluna se
-- acrescenta sem mexer no que já está aqui.
-- ============================================================

alter table public.avaliadores
  add column if not exists presente     boolean not null default false,
  add column if not exists presente_em  timestamptz,
  add column if not exists presente_por uuid references public.avaliadores(id);

comment on column public.avaliadores.presente is
  'Representante credenciado no dia: recebeu crachá e kit.';

-- ------------------------------------------------------------
-- lista_avaliadores(): a lista da mesa
--
-- Só quem é `avaliador`. Gestor e diretoria são a organização —
-- não passam pelo balcão de representantes.
-- ------------------------------------------------------------
create or replace function public.lista_avaliadores()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := public.exigir_gestor();
begin
  return jsonb_build_object(
    'resumo', (
      select jsonb_build_object(
        'total',     count(*),
        'presentes', count(*) filter (where presente))
        from avaliadores where papel = 'avaliador'
    ),
    'pessoas', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'id',       a.id,
                 'nome',     a.nome,
                 'email',    a.email,
                 'onde',     a.organizacao,
                 'presente', a.presente,
                 'em',       a.presente_em,
                 'por',      (select g.nome from avaliadores g where g.id = a.presente_por))
               order by public.chave_nome(a.nome))
        from avaliadores a
       where a.papel = 'avaliador'
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.lista_avaliadores() from public, anon;
grant  execute on function public.lista_avaliadores() to authenticated;

-- ------------------------------------------------------------
-- marcar_avaliador(id, presente)
--
-- Função própria, e não um terceiro `kind` na marcar_presenca da
-- 0025: aquela função é usada por duas telas e está funcionando
-- há semanas. Acrescentar um ramo nela significaria recriá-la
-- inteira na véspera do evento, para ganhar nada.
--
-- Idempotente: marcar duas vezes não estraga.
-- ------------------------------------------------------------
create or replace function public.marcar_avaliador(p_id uuid, p_presente boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gestor uuid := public.exigir_gestor();
begin
  update avaliadores
     set presente     = p_presente,
         presente_em  = case when p_presente then now() else null end,
         presente_por = case when p_presente then v_gestor else null end
   where id = p_id and papel = 'avaliador';

  if not found then
    raise exception 'nao_encontrado';
  end if;

  return jsonb_build_object('ok', true, 'presente', p_presente);
end;
$$;

revoke execute on function public.marcar_avaliador(uuid, boolean) from public, anon;
grant  execute on function public.marcar_avaliador(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- DEPOIS DO EVENTO
--
-- Quem veio e quem não veio:
--
--   select nome, organizacao, email,
--          case when presente then to_char(presente_em, 'HH24:MI') else '—' end as chegou
--     from public.avaliadores
--    where papel = 'avaliador'
--    order by presente desc, public.chave_nome(nome);
--
-- Taxa de comparecimento dos representantes:
--
--   select count(*) filter (where presente) as vieram, count(*) as convidados
--     from public.avaliadores where papel = 'avaliador';
-- ------------------------------------------------------------
