-- ============================================================
-- 0039 — Proteção da inscrição nas palestras
--
-- Substitui a inscrever_palestra da 0038. Mantém tudo o que ela
-- fazia (inclusive o `perfil`) e fecha dois buracos encontrados
-- numa revisão do SQL antes de o comunicado sair.
--
-- 1. ERA A ÚNICA ESCRITA PÚBLICA SEM FREIO DE INUNDAÇÃO
--
-- Todas as outras funções abertas ao anon começam com o bloco da
-- 0013: pega o IP do cabeçalho, gera um hash com o sal, e recusa
-- quem passou do teto em 10 minutos. Esta não tinha nada disso —
-- nem o segredo de cartaz que a inscrever_na_feira exige.
--
-- A chave anon está no código-fonte de palestras.html, que é
-- público por natureza. Um laço trivial preencheria as 100 vagas
-- das duas salas em segundos, com nomes inventados. E aqui o
-- recurso é finito: desfazer significa apagar linha por linha, na
-- véspera, sem saber quais eram legítimas.
--
-- Teto de 6 por IP em 10 minutos, como na 0032 — aqui cada pessoa
-- se inscreve uma vez. E um teto global de 300, que na 0013 é
-- rede de segurança e aqui é mais que isso: o total de vagas é
-- 100.
--
-- 2. A TRAVA ERA POR PALESTRA; A UNICIDADE É POR E-MAIL
--
-- `pg_advisory_xact_lock('palestra:' || codigo)` serializa quem
-- disputa a MESMA sala — e isso protege corretamente a contagem
-- de vagas.
--
-- Mas o índice único é sobre `lower(email)` SEM a palestra. Dois
-- pedidos do mesmo e-mail para palestras DIFERENTES pegam travas
-- diferentes, não se serializam, nenhum enxerga a linha do outro
-- (que ainda não commitou), e o segundo bate no índice: erro
-- 23505 cru subindo até a tela da família como "duplicate key
-- value violates unique constraint".
--
-- Entra uma segunda trava, na chave do invariante que se quer
-- defender: o e-mail. A ordem é sempre palestra e depois e-mail,
-- e ninguém pede duas travas de palestra — não há ciclo, logo não
-- há deadlock.
--
-- E um cinto de segurança: se ainda assim o índice for violado
-- por algum caminho, o handler devolve o mesmo `ja_inscrito`
-- amigável em vez do erro do Postgres.
-- ============================================================

create or replace function public.inscrever_palestra(p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_codigo     text := nullif(trim(p_dados->>'palestra'), '');
  v_nome       text := nullif(trim(p_dados->>'nome'), '');
  v_email      text := lower(nullif(trim(p_dados->>'email'), ''));
  v_tel        text := nullif(trim(p_dados->>'telefone'), '');
  v_perfil     text := coalesce(nullif(trim(p_dados->>'perfil'), ''), 'aluno');
  v_p          record;
  v_ja         record;
  v_ocupadas   integer;
  v_cabecalhos jsonb;
  v_ip         text;
  v_ip_hash    text;
begin
  -- ---- freio de inundação (0013) ----
  v_cabecalhos := nullif(current_setting('request.headers', true), '')::jsonb;

  if v_cabecalhos is not null then
    v_ip := nullif(trim(coalesce(
      v_cabecalhos->>'cf-connecting-ip',
      split_part(v_cabecalhos->>'x-forwarded-for', ',', 1)
    )), '');
  end if;

  if v_ip is not null then
    /* sha256() nativo, nunca digest() do pgcrypto: o search_path
       desta função é public, pg_temp, e no Supabase o pgcrypto
       vive em `extensions` — seria "function does not exist" na
       primeira inscrição real. Mesma armadilha registrada na
       0013. */
    v_ip_hash := encode(
      sha256((v_ip || (select valor from segredos where chave = 'sal_ip'))::bytea),
      'hex');

    if (select count(*) from inscricao_tentativas
         where ip_hash = v_ip_hash
           and em > now() - interval '10 minutes') >= 6 then
      raise exception 'muitas_tentativas';
    end if;
  end if;

  /* Teto global. Na 0013 é rede de segurança; aqui é mais que
     isso, porque o total de vagas é 100 e não se recupera. */
  if (select count(*) from inscricao_tentativas
       where em > now() - interval '10 minutes') >= 300 then
    raise exception 'muitas_tentativas';
  end if;

  -- ---- validações ----
  if v_nome is null or array_length(string_to_array(v_nome, ' '), 1) < 2 then
    raise exception 'nome_incompleto';
  end if;
  if v_email is null
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'email_invalido';
  end if;
  if v_perfil not in ('aluno', 'responsavel', 'externo') then
    raise exception 'perfil_invalido';
  end if;

  select * into v_p from palestras where codigo = v_codigo and ativa;
  if not found then
    raise exception 'palestra_invalida';
  end if;

  /* Duas travas, nesta ordem:
       1. a palestra  — protege a contagem de vagas
       2. o e-mail    — protege a unicidade, que é global
     Sem a segunda, o mesmo e-mail em salas diferentes escapa. */
  perform pg_advisory_xact_lock(1, hashtext(v_codigo));
  perform pg_advisory_xact_lock(2, hashtext(v_email));

  select i.palestra_codigo, p.titulo
    into v_ja
    from palestra_inscricoes i
    join palestras p on p.codigo = i.palestra_codigo
   where lower(i.email) = v_email;

  if found then
    return jsonb_build_object(
      'ok', false, 'motivo', 'ja_inscrito',
      'palestra', v_ja.palestra_codigo, 'titulo', v_ja.titulo);
  end if;

  select count(*) into v_ocupadas
    from palestra_inscricoes where palestra_codigo = v_codigo;

  if v_ocupadas >= v_p.vagas then
    return jsonb_build_object('ok', false, 'motivo', 'lotada', 'titulo', v_p.titulo);
  end if;

  /* A tentativa só é contabilizada aqui, quando a inscrição vai
     de fato ocupar vaga. Recusa por já-inscrito ou por sala cheia
     não consome cota — erro de quem tenta de novo achando que
     falhou não pode virar bloqueio. */
  insert into inscricao_tentativas (ip_hash)
  values (coalesce(v_ip_hash, 'sem-origem'));

  delete from inscricao_tentativas where em < now() - interval '2 hours';

  begin
    insert into palestra_inscricoes (palestra_codigo, nome, email, telefone, perfil)
    values (v_codigo, v_nome, v_email, v_tel, v_perfil);
  exception when unique_violation then
    /* Cinto de segurança: depois do rollback ao savepoint
       implícito, a linha do outro já está visível. */
    select i.palestra_codigo, p.titulo
      into v_ja
      from palestra_inscricoes i
      join palestras p on p.codigo = i.palestra_codigo
     where lower(i.email) = v_email;

    return jsonb_build_object(
      'ok', false, 'motivo', 'ja_inscrito',
      'palestra', v_ja.palestra_codigo, 'titulo', v_ja.titulo);
  end;

  return jsonb_build_object(
    'ok', true,
    'titulo', v_p.titulo,
    'palestrante', v_p.palestrante,
    'posicao', v_ocupadas + 1,
    'restantes', v_p.vagas - v_ocupadas - 1);
end;
$$;

revoke execute on function public.inscrever_palestra(jsonb) from public;
grant  execute on function public.inscrever_palestra(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- SE ALGUÉM FOR BLOQUEADO INJUSTAMENTE
--
-- Uma família inteira no mesmo Wi-Fi conta como um IP. Seis
-- inscrições em 10 minutos da mesma casa é cenário real numa
-- escola. Para liberar na hora:
--
--   delete from public.inscricao_tentativas
--    where em > now() - interval '10 minutes';
--
-- Isso zera o contador de todo mundo, o que é aceitável: a janela
-- é de 10 minutos e se refaz sozinha.
-- ------------------------------------------------------------
