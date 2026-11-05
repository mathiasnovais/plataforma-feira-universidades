# Cadastrar os avaliadores

Um avaliador precisa existir em **dois lugares** para o app funcionar:

| Onde | O que é | Se faltar |
|---|---|---|
| `auth.users` | a conta que recebe o código por e-mail | login recusado: *"E-mail não cadastrado como avaliador"* |
| `public.avaliadores` | a autorização de ler dados de aluno | login entra, mas escanear dá *"não está na lista de avaliadores"* |

Os dois erros já aconteceram nos testes. O script abaixo resolve os dois
lados de uma vez.

---

## Caminho normal — em lote, por CSV

### 1. Montar o CSV

Salve como `avaliadores.csv` na pasta do projeto, com o cabeçalho exato:

```csv
nome,email,organizacao
Maria Souza,maria@empresa.com,Empresa X
João Lima,joao.lima@universidade.edu.br,Universidade Y
Ana Prado,ana@consultoria.com.br,
```

- `nome` e `email` são obrigatórios; linha sem um dos dois é pulada e reportada
- `organizacao` pode ficar vazia
- Vírgula dentro de um campo exige aspas: `"Souza, Maria"`
- E-mail é normalizado para minúsculas

### 2. Rodar

Supabase → **Settings** → **API Keys** → aba **Legacy** → `service_role` →
**Reveal** → copiar. Depois, no terminal do VS Code:

```powershell
$env:SUPABASE_SERVICE_ROLE = "cole_a_chave_aqui"
node scripts/criar-avaliadores.mjs avaliadores.csv
```

Saída esperada:

```
104 linha(s) no CSV.
1 usuário(s) já em auth.users.
criados: 103  |  já existiam: 1  |  falhas: 0
104 linha(s) em public.avaliadores.
```

**Rodar duas vezes não duplica.** Quem já existe é reaproveitado. Então dá
para receber a lista em partes e rodar de novo a cada lote novo.

Se aparecer `falhas`, revise as linhas apontadas antes do evento. Um
avaliador que falhou aqui não consegue entrar no dia.

### 3. Conferir

```sql
select a.nome, a.email, a.organizacao,
       u.email_confirmed_at is not null as pode_logar
  from public.avaliadores a
  join auth.users u on u.id = a.id
 order by a.nome;
```

`pode_logar = false` significa conta não confirmada — o script já cria
confirmada, então isso indica usuário criado à mão sem marcar *Auto
Confirm User*.

Para achar quem ficou pela metade:

```sql
-- Está no auth mas não é avaliador: entra e não consegue escanear
select u.email from auth.users u
 where not exists (select 1 from public.avaliadores a where a.id = u.id);
```

---

## Caminho manual — um avaliador só

Serve para quando alguém aparece na hora do evento.

**1.** Supabase → **Authentication** → **Users** → **Add user** →
*Create new user*

- Email: o do avaliador
- Password: qualquer coisa (nunca será usada, o login é por código)
- **Auto Confirm User: marcado** — sem isso o código não chega

**2.** No SQL Editor:

```sql
insert into public.avaliadores (id, nome, email, organizacao)
select u.id, 'NOME DO AVALIADOR', u.email, 'ORGANIZAÇÃO'
  from auth.users u
 where u.email = 'email@do.avaliador'
on conflict (id) do nothing
returning *;
```

O `returning *` é importante: se voltar **zero linhas**, o usuário não
existe em `auth.users` e o passo 1 não funcionou. Sem ele, o comando
responde sucesso mesmo sem gravar nada.

---

## Remover um avaliador

```sql
-- Apaga a conta; a linha em avaliadores cai por cascade,
-- e os contatos que ele salvou também.
delete from auth.users where email = 'email@do.avaliador';
```

Se quiser só revogar o acesso mantendo os contatos que ele já salvou:

```sql
delete from public.avaliadores where email = 'email@do.avaliador';
```

Ele continua conseguindo logar, mas não lê nem salva nada.

---

## Na véspera do evento

Item 10 da ordem de execução, e vale tratar como obrigatório:

**Mande o link do app para todos os avaliadores no dia anterior, pedindo
que entrem uma vez.** A sessão fica guardada no celular e no dia do evento
eles abrem o app já logados.

Isso elimina o pico de e-mails na abertura, que é o risco 3 da tabela de
riscos. Sem essa medida, 100 pessoas pedindo código às 8h da manhã
disputam o limite de 200 e-mails/hora ao mesmo tempo — e quem depender de
e-mail nesse momento fica na fila.

Junto do link, vale um card impresso com três passos: *abra o link → digite
seu e-mail → digite o código que chegou*.
