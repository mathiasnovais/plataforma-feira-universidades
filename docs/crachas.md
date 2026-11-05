# Gerar e imprimir os crachás com QR

## Antes de começar

**A URL do app precisa estar definitiva.** Ela vai impressa dentro de cada
QR code. Trocar de domínio depois obriga a reimprimir tudo.

URL atual: `https://fair.alfacem-global-academy.workers.dev`

Se for apontar um domínio próprio (`feira.alfacem.com.br`), faça isso
**antes** de gerar.

**Só entram inscritos com `ativo = true`.** Quem chega pelo formulário de
inscrição entra como `ativo = false` e precisa ser revisado antes
(`docs/inscricoes.md`).

**Resolva as duplicatas primeiro.** Cada nome repetido que escapar vira dois
crachás com QRs diferentes para a mesma pessoa, e a leva carimba os dois:

```powershell
node scripts/duplicatas.mjs
```

Passo a passo em `docs/inscricoes.md`, seção 2.

---

## Como funcionam as levas

A aprovação não acontece de uma vez só: você aprova um grupo, imprime, e na
semana seguinte chega mais gente. Se cada geração trouxesse todo mundo com
`ativo = true`, a segunda sairia com os 300 já impressos junto com os 40
novos.

Crachá duplicado é pior do que desperdício de papel: são dois papéis com o
mesmo QR circulando no salão, e a lista de presença não sabe qual dos dois
entrou.

Por isso o script trabalha por **leva**:

```
inscrito aprovado         →  entra na fila (cracha_lote is null)
geração                   →  carimba a fila inteira como leva N
inscrito da leva N        →  nunca mais volta sozinho
```

Quem já foi carimbado só reaparece se você pedir aquela leva de volta, por
nome e número. Acompanhante não tem leva própria — ele herda a do aluno,
porque o crachá dele carrega o token do aluno e os dois são recortados
juntos.

**Se você já imprimiu crachás antes de existir esse controle**, carimbe essa
gente uma única vez antes de gerar a próxima leva, senão eles voltam:

```sql
update public.alunos
   set cracha_lote = 1, cracha_gerado_em = now()
 where ativo and cracha_lote is null;
```

---

## 1. Conferir quem vai sair

Com a `service_role` já na variável de ambiente (passo 2):

```powershell
node scripts/gerar-crachas.mjs --situacao
```

```
LEVA        INSCRITOS  ACOMPANHANTES  CRACHÁS  GERADA EM
leva 1            312            428      740  05/08/2026 10:12
na fila            40             57       97  —

97 crachá(s) esperando. Gere com o comando sem opções.
```

No SQL Editor do Supabase, a checagem que o script não faz:

```sql
select count(*) filter (where not ativo)                     as aguardando_revisao,
       count(*) filter (where not consentimento_responsavel) as sem_consentimento
  from public.alunos;
```

`sem_consentimento` maior que zero merece atenção: esses inscritos ganham
crachá, mas o app não mostra nem salva nada deles. Ou o consentimento não foi
importado, ou eles realmente não devem estar na feira.

---

## 2. Pegar a service_role

Supabase → **Settings** → **API Keys** → aba **Legacy anon, service_role
API keys** → linha `service_role` → **Reveal** → copiar.

Essa chave ignora toda a segurança do banco. Ela só existe dentro da
janela do terminal e some quando você fecha.

```powershell
$env:SUPABASE_SERVICE_ROLE = "cole_a_chave_aqui"
```

---

## 3. Gerar a leva

Conferir a fila sem tirar ninguém dela:

```powershell
node scripts/gerar-crachas.mjs https://fair.alfacem-global-academy.workers.dev --sem-marcar
```

Gera os `saida/crachas-fila-*.html` e não carimba nada. É para abrir, contar e
conferir com a secretaria. **Não imprima esse arquivo** — a gente dele
continua na fila e sairia de novo na leva seguinte.

Valendo:

```powershell
node scripts/gerar-crachas.mjs https://fair.alfacem-global-academy.workers.dev
```

```
Leva 2: 40 inscrito(s) carimbado(s) e fora da fila.

97 crachá(s) em 3 arquivo(s):
    38  Alunos               saida/crachas-leva-002-alunos.html
    57  Responsáveis         saida/crachas-leva-002-responsaveis.html
     2  College Counselors   saida/crachas-leva-002-counselors.html

URL no QR: https://fair.alfacem-global-academy.workers.dev/#/p/<token>

Esta é a leva 2. Essa gente não volta em geração nenhuma daqui
em diante. Se o arquivo não for impresso, devolva todos para a fila com:
  node scripts/gerar-crachas.mjs --desmarcar 2
Para reimprimir a mesma leva depois: --lote 2
```

O carimbo acontece **antes** de o arquivo ser escrito, num único comando no
banco. Se o arquivo se perder, `--lote 2` reconstrói exatamente a mesma leva
— não existe estado a recuperar a mão.

Para conferir o layout sem tocar no banco:

```powershell
node scripts/gerar-crachas.mjs https://fair.alfacem-global-academy.workers.dev --exemplo
```

---

## 4. Imprimir

**Sai um arquivo por categoria**, não um só: alunos, responsáveis, college
counselors e docentes. É assim que os crachás são separados na mesa — o do
aluno vai para o kit da turma, o do responsável é entregue na entrada, e
counselor e docente são recebidos à parte. Num PDF único seria preciso
recortar as 37 folhas e reagrupar 515 papéis à mão.

O crachá do responsável diz **Responsável ·** seguido da mesma série e
unidade do aluno. Nem o parentesco ("Mãe", "Pai") nem o nome do aluno vão
para o papel — o que amarra os dois é o código curto impresso embaixo, que é
o do aluno, e o QR, que abre o perfil dele. O parentesco continua no banco,
para a lista de presença.

Abra **cada arquivo** no navegador, um de cada vez, e tecle **Ctrl+P**.

| Opção | Valor | Por quê |
|---|---|---|
| Destino | Salvar como PDF | facilita levar à gráfica |
| Escala | **100%** | reduzir encolhe o QR e piora a leitura |
| Gráficos de fundo | **ligado** | sem isso as cores somem |
| Margens | padrão | o layout já reserva o espaço |

São 14 crachás por folha A4 (2 colunas x 7 linhas), com linha tracejada de
corte. O botão **Gerar PDF** na própria página é a alternativa quando a
gráfica pede vetor limpo, e o **ZIP de PNG** quando ela só aceita imagem.

---

## 5. Testar antes de imprimir tudo

**Imprima uma folha só.** Recorte, e com o celular:

1. Escaneie os 14 pelo app — todos devem abrir o perfil
2. Escaneie **sob a luz do local do evento**, não na sua mesa
3. Amasse um deles e escaneie de novo
4. Digite o código curto de um deles na entrada manual

Se algum QR não ler amassado, aumente `CRACHA.qr` e `.qr` de `34mm` para
`38mm` em `scripts/gerar-crachas.mjs` — as duas medidas, que são dois motores
de desenho diferentes — e gere a leva de novo com `--lote N`.

Só depois disso mande o resto das folhas.

---

## 6. Depois de imprimir

Apague os arquivos de `saida/`. Eles contêm nome e token de todos os
inscritos — dado pessoal de menor de idade. Não podem ir para a hospedagem,
nem para o Drive, nem para o e-mail da gráfica sem necessidade.

Se a gráfica precisar do arquivo, mande o **PDF**, não o HTML.

Apagar o HTML não perde nada: `--lote N` regenera a leva inteira quando
precisar.

---

## Quando algo dá errado

**Gerei mas não vou imprimir** (arquivo errado, URL errada, desistiu):

```powershell
node scripts/gerar-crachas.mjs --desmarcar 2
```

Todo mundo volta para a fila e entra na próxima geração. Apague o arquivo
dessa leva em `saida/` para não imprimir por engano depois.

**A leva imprimiu torto / a gráfica perdeu:**

```powershell
node scripts/gerar-crachas.mjs https://fair.alfacem-global-academy.workers.dev --lote 2
```

Mesma gente, mesmo arquivo, sem carimbar nada de novo.

**Uma pessoa só perdeu o crachá antes da entrega** (o papel nunca chegou na
mão dela, então o token não vazou):

```sql
update public.alunos
   set cracha_lote = null, cracha_gerado_em = null
 where codigo_curto = 'K7M2QX';
```

Ela volta para a fila e sai na próxima leva.

**Troquei de domínio e todo QR morreu:**

```powershell
node scripts/gerar-crachas.mjs https://NOVO-DOMINIO --tudo
```

Traz todos os ativos, ignorando as levas, sem carimbar. É o único caso em que
reimprimir por cima de crachá já entregue é o certo.

---

## Reemissão de crachá perdido depois de entregue

Diferente dos casos acima: o papel está solto no mundo, e enquanto o token
viver ele abre o perfil do aluno para quem achar.

```sql
-- Gera token e código novos. O crachá antigo para de funcionar.
update public.alunos
   set cracha_token = public.gen_cracha_token(),
       codigo_curto = public.gen_codigo_curto(),
       cracha_lote = null,
       cracha_gerado_em = null
 where codigo_curto = 'CODIGO_ANTIGO'
returning nome, codigo_curto, cracha_token;
```

O `cracha_lote = null` devolve a pessoa para a fila. Gere a próxima leva
normalmente e imprima só a folha dela.
