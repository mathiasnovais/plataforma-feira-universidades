-- ============================================================
-- 0016 — Números do painel, sem dado pessoal
--
-- A direção quer acompanhar as inscrições sem depender de alguém
-- rodar script e mandar arquivo. Isso pede uma página com link,
-- e link significa que qualquer um que o tenha vê o conteúdo.
--
-- Por isso esta função devolve SÓ CONTAGENS. Nenhum nome, nenhum
-- e-mail, nenhum id, nenhuma data de nascimento — nada que
-- identifique uma pessoa. O que sai daqui é "47 alunos da Barra
-- Américas", não quem são.
--
-- É o que torna seguro publicar a página junto do formulário e
-- mandar o endereço para quem precisar.
--
-- Para ver nome, contato e duplicatas — o que a revisão exige —
-- existe o scripts/painel.mjs, que roda local, com service_role,
-- e escreve um arquivo que não se publica.
-- ============================================================

create or replace function public.painel_publico()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'atualizado_em', now(),

    'totais', (
      select jsonb_build_object(
        'inscricoes',   count(*),
        'alunos',       count(*) filter (where tipo <> 'counselor'),
        'counselors',   count(*) filter (where tipo = 'counselor'),
        'aprovados',    count(*) filter (where ativo),
        'pendentes',    count(*) filter (where not ativo)
      ) from alunos
    ),

    'acompanhantes', (select count(*) from acompanhantes),

    -- Quantos crachás sairão da impressão, contando acompanhante
    -- de aluno já aprovado.
    'crachas', jsonb_build_object(
      'total',     (select count(*) from alunos) + (select count(*) from acompanhantes),
      'aprovados', (select count(*) from alunos where ativo)
                 + (select count(*) from acompanhantes c
                     join alunos a on a.id = c.aluno_id where a.ativo)
    ),

    'por_unidade', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by n desc, rotulo), '[]'::jsonb)
        from (select coalesce(unidade, colegio, 'não informado') as rotulo, count(*) as n
                from alunos where tipo <> 'counselor'
               group by 1) q
    ),

    'por_ano', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by rotulo), '[]'::jsonb)
        from (select coalesce(ano_escolaridade, 'não informado') as rotulo, count(*) as n
                from alunos where tipo <> 'counselor'
               group by 1) q
    ),

    'por_pais', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by n desc, rotulo), '[]'::jsonb)
        from (select unnest(paises_interesse) as rotulo, count(*) as n
                from alunos where tipo <> 'counselor' and paises_interesse is not null
               group by 1) q
    ),

    'por_acompanhamento', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by n desc), '[]'::jsonb)
        from (select coalesce(responsavel_acompanha, 'não informado') as rotulo, count(*) as n
                from alunos where tipo <> 'counselor'
               group by 1) q
    ),

    -- Instituições dos counselors: é nome de escola, não de
    -- pessoa. Ainda assim fica sem a contagem por nome próprio.
    'por_instituicao_counselor', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by n desc, rotulo), '[]'::jsonb)
        from (select coalesce(colegio, 'não informado') as rotulo, count(*) as n
                from alunos where tipo = 'counselor'
               group by 1) q
    ),

    'por_dia', (
      select coalesce(jsonb_agg(jsonb_build_object('rotulo', rotulo, 'n', n)
                                order by rotulo), '[]'::jsonb)
        from (select to_char(criado_em at time zone 'America/Sao_Paulo', 'YYYY-MM-DD') as rotulo,
                     count(*) as n
                from alunos
               where criado_em > now() - interval '45 days'
               group by 1) q
    )
  );
$$;

-- ------------------------------------------------------------
-- Aberta para anon: é o que permite a página do painel funcionar
-- com a mesma chave pública do formulário, sem inventar login.
--
-- O que ela expõe a quem tiver o endereço: quantas inscrições
-- existem, por unidade, por série, por país de interesse e por
-- dia. Nada que aponte para uma pessoa.
--
-- Se um dia até esses números precisarem ser privados, o caminho
-- é pôr a página atrás do Cloudflare Access — não é revogar este
-- grant, que quebraria o painel sem proteger mais nada.
-- ------------------------------------------------------------
revoke execute on function public.painel_publico() from public;
grant  execute on function public.painel_publico() to anon, authenticated;

-- ------------------------------------------------------------
-- Conferir depois de rodar:
--
--   select public.painel_publico();
--
-- E procure no resultado por qualquer nome ou e-mail. Não deve
-- haver nenhum — se houver, algo saiu errado e a página não pode
-- ser publicada.
-- ------------------------------------------------------------
