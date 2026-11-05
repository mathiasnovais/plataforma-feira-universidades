-- ============================================================
-- 0021 — Fila de e-mail: docente entra, endereço quebrado sai
--
-- Dois defeitos, encontrados quando o nó do Gmail respondeu
-- "Invalid To header" e parou o lote.
--
-- 1. DOCENTE NUNCA RECEBIA
--
-- A 0015 escolhia o destinatário com
--     case when tipo = 'counselor' then email else responsavel_email end
-- porque naquele momento só existiam dois tipos. Com o docente da
-- 0019, ele caiu no `else` e foi buscar responsavel_email, que é
-- nulo para quem se inscreve sozinho. O filtro então o excluía da
-- fila — sem erro, sem aviso, sem e-mail.
--
-- É o mesmo padrão que a 0020 corrigiu no painel: expressão que
-- dizia "counselor ou o resto" quando queria dizer "quem se
-- inscreve sozinho". Agora pergunta pelo que importa: é aluno?
--
-- 2. UM ENDEREÇO QUEBRADO DERRUBAVA TODOS
--
-- O n8n manda o lote inteiro numa execução. Um endereço que o
-- Gmail recusa aborta a execução, e quem estava depois na fila
-- não recebe — nem naquela passada, nem nas seguintes, porque o
-- erro se repete sempre no mesmo ponto.
--
-- Uma linha ruim travando 300 boas é o pior comportamento
-- possível. Endereço que não passa no formato básico fica fora
-- da fila; a consulta no rodapé mostra quais são, para a
-- organização corrigir à mão.
-- ============================================================

create or replace function public.emails_pendentes(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ok boolean;
begin
  select valor = p_token into v_ok
    from segredos where chave = 'token_n8n';

  if not coalesce(v_ok, false) then
    raise exception 'token_invalido';
  end if;

  return coalesce((
    select jsonb_agg(linha order by linha->>'criado_em')
      from (
        select jsonb_build_object(
                 'id',         a.id,
                 'tipo',       a.tipo,
                 'nome',       a.nome,
                 -- Aluno responde pelo responsável; counselor e
                 -- docente respondem por si.
                 'destino',    case when a.tipo = 'aluno'
                                    then a.responsavel_email
                                    else a.email end,
                 'destinatario', case when a.tipo = 'aluno'
                                      then a.responsavel_nome
                                      else a.nome end,
                 'aluno',      case when a.tipo = 'aluno' then a.nome end,
                 'instituicao', coalesce(a.colegio, a.unidade),
                 'ano',        a.ano_escolaridade,
                 'acompanhantes', coalesce((
                    select jsonb_agg(c.nome order by c.nome)
                      from acompanhantes c where c.aluno_id = a.id), '[]'::jsonb),
                 'protocolo',  upper(substr(replace(a.id::text, '-', ''), 1, 8)),
                 'criado_em',  a.criado_em
               ) as linha
          from alunos a
         where a.email_confirmacao_em is null
           -- Mesmo formato que as funções de inscrição exigem. O
           -- que não passa aqui não passaria no Gmail.
           and coalesce(case when a.tipo = 'aluno' then a.responsavel_email else a.email end, '')
               ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
         order by a.criado_em
         limit 50
      ) q
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.emails_pendentes(text) from public;
grant  execute on function public.emails_pendentes(text) to anon, authenticated;

-- ------------------------------------------------------------
-- Quem ficou de fora, e por quê
--
-- Rode esta consulta de tempos em tempos até o evento. Ela lista
-- quem nunca vai receber confirmação enquanto ninguém corrigir o
-- endereço à mão.
--
--   select tipo, nome,
--          case when tipo = 'aluno' then responsavel_email else email end as destino,
--          criado_em
--     from public.alunos
--    where email_confirmacao_em is null
--      and coalesce(case when tipo = 'aluno' then responsavel_email else email end, '')
--          !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
--    order by criado_em;
--
-- Para corrigir um endereço e devolver a pessoa à fila:
--
--   update public.alunos
--      set responsavel_email = 'endereco@corrigido.com'
--    where id = 'cole-o-id-aqui';
--
-- (para counselor e docente, a coluna é `email`)
--
-- E para reenviar a confirmação de alguém que já recebeu:
--
--   update public.alunos set email_confirmacao_em = null where id = '...';
--
-- CONFERIR DEPOIS DE RODAR
--
--   select jsonb_array_length(public.emails_pendentes('cole-o-token'));
--
-- Os docentes pendentes passam a aparecer; o endereço quebrado,
-- não.
-- ------------------------------------------------------------
