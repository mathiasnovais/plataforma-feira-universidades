# Revisar e aprovar as inscrições

## Por que existe essa etapa

O formulário é público: qualquer pessoa com o link consegue enviar. Se a
inscrição virasse aluno ativo na hora, bastaria alguém malicioso — ou um
teste esquecido — para poluir a lista que gera os 600 crachás.

Por isso toda inscrição entra com `ativo = false`. Nesse estado ela:

- **não gera crachá** (`gerar-crachas.mjs` filtra `ativo = true`)
- **não é encontrável** pelo app, nem com o token correto
- fica guardada, sem nada se perder

É uma revisão só, no fim do período de inscrição. Não é aprovar de um em um
conforme chegam.

---

## O fluxo

```
inscrições chegam durante semanas   →   ativo = false
        ↓
período encerra
        ↓
organização confere a lista          ←   você está aqui
        ↓
aprova em lote                       →   ativo = true
        ↓
gera e imprime os crachás
```

---

## 1. Ver a fila

```sql
select nome,
       responsavel_nome,
       responsavel_email,
       case when aluno_alfacem then unidade else coalesce(colegio, '—') end as escola,
       ano_escolaridade,
       criado_em
  from public.alunos
 where not ativo
 order by criado_em;
```

## 2. Procurar duplicatas

Família que preenche duas vezes por achar que não enviou é o caso mais
comum. Duas linhas viram dois crachás com QRs diferentes para a mesma
pessoa — e no dia, a lista de presença não sabe qual dos dois entrou.

O painel avisa que existem. Para decidir o que fazer com cada uma:

```powershell
$env:SUPABASE_SERVICE_ROLE = "cole_a_chave_aqui"
node scripts/duplicatas.mjs
```

Ele mostra as linhas lado a lado — série, unidade, responsável, telefone,
acompanhantes, data — e separa em três:

| Veredicto | O que é | O que fazer |
|---|---|---|
| **CERTA** | nome completo idêntico e mesmo contato (inclusive com erro de digitação, tipo `@gmail.comf`) | apagar a repetida |
| **PROVAVEL** | nome completo idêntico, contatos diferentes — quase sempre pai e mãe preenchendo cada um o seu | ligar para confirmar, depois apagar |
| **VERIFICAR** | só o primeiro e o último nome batem | provável homônimo; não mexer sem confirmar |

O terceiro caso existe porque o agrupamento do painel usa `chave_nome()` —
primeiro + último nome ([0024](../supabase/migrations/0024_bloquear_duplicata.sql)).
Isso é proposital, para pegar "Ana Beatriz Silva" e "Ana Silva" como a mesma
pessoa, mas junta no mesmo grupo duas "Maria … Nascimento" sem parentesco
nenhum. Nome repetido não é prova de duplicata.

O script escreve `saida/duplicatas.sql` com a limpeza pronta para revisar.
Ele não altera nada sozinho — os grupos PROVAVEL saem comentados, e os
VERIFICAR não saem.

**Por que não sair apagando por SQL direto:** `delete` em `alunos` cascateia
para `acompanhantes` ([0012](../supabase/migrations/0012_acompanhantes.sql)).
Se a linha que você apagar for a que tinha os pais cadastrados, eles somem
junto — sem erro na tela, e o crachá deles simplesmente não sai. Por isso o
roteiro gerado move o acompanhante para a linha que fica **antes** do delete.

Se o script não estiver disponível, a consulta equivalente no SQL Editor:

```sql
with grupos as (
  select public.chave_nome(nome) as chave
    from public.alunos
   where nome is not null and trim(nome) <> ''
   group by 1 having count(*) > 1
)
select a.nome, a.tipo, a.ano_escolaridade,
       coalesce(a.unidade, a.colegio)          as onde,
       a.responsavel_nome,
       coalesce(a.responsavel_email, a.email)  as contato,
       coalesce(a.responsavel_telefone, a.telefone) as telefone,
       a.ativo, a.codigo_curto, a.criado_em,
       (select count(*) from public.acompanhantes c where c.aluno_id = a.id) as acomp,
       a.id
  from public.alunos a
  join grupos g on g.chave = public.chave_nome(a.nome)
 order by public.chave_nome(a.nome), a.criado_em;
```

## 3. Conferir o que compromete o evento

```sql
select count(*)                                             as total,
       count(*) filter (where not consentimento_responsavel) as sem_consentimento,
       count(*) filter (where nivel_compartilhamento = 0
                          and not compartilhar_responsavel)  as sem_nenhum_contato,
       count(*) filter (where responsavel_email is null)     as sem_email_do_resp
  from public.alunos
 where not ativo;
```

`sem_nenhum_contato` merece atenção: esses alunos recebem crachá, aparecem
para o representante com o nome, mas não podem ser salvos. É uma escolha
legítima da família — só não pode ser surpresa no dia.

## 4. Aprovar

Tudo de uma vez, depois de conferir:

```sql
update public.alunos set ativo = true where not ativo;
```

Uma inscrição específica:

```sql
update public.alunos set ativo = true
 where responsavel_email = 'email@da.familia' and nome = 'Nome do Aluno';
```

## 5. Recusar

```sql
delete from public.alunos
 where not ativo and nome = 'Nome do Aluno';
```

O `delete` cascateia: contatos salvos e registros de acesso caem junto
(migration 0008). É também o comando que atende pedido de exclusão de dados
feito pelo responsável.

---

## Pela interface, sem SQL

Quem for revisar não precisa saber SQL. No painel do Supabase:

**Table Editor** → tabela `alunos` → **Filter** → `ativo` `is` `false`.

A lista aparece em planilha. Dá para editar a coluna `ativo` linha a linha
clicando na célula, e para exportar em CSV pelo botão de download — útil
para conferir com a secretaria antes de aprovar.

Foi por isso que os requisitos descartaram construir painel administrativo:
o Table Editor já é isso.

---

## Depois de aprovar

1. Gerar os crachás — `docs/crachas.md`
2. Pode aprovar em lote de novo depois de imprimir. Quem for aprovado
   depois entra na fila e sai na leva seguinte; quem já imprimiu fica
   carimbado e não volta (migration 0027). Não existe mais o risco de
   sair crachá duplicado por aprovar duas vezes.

Inscrição que chegar depois da última impressão vira uma leva nova, por
menor que seja — `node scripts/gerar-crachas.mjs https://SEU-DOMINIO` traz
só ela. Ainda vale definir uma data de corte e comunicá-la às famílias, mas
por causa do prazo da gráfica, não por limitação do sistema.
