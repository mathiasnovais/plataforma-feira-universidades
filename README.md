# Feira de universidades: inscrição, crachá e painel ao vivo

Plataforma usada numa feira de universidades com cerca de 600 participantes.
Cada aluno recebe um crachá com QR; na portaria a equipe lê o QR e marca a
presença; nos estandes os representantes das universidades leem o mesmo QR
para guardar o contato do aluno (lead); a direção acompanha um painel ao vivo
com quem já entrou. O app dos representantes é um PWA e funciona sem rede,
sincronizando quando o Wi-Fi volta.

A versão enxuta (raiz do repositório) é a da feira local: a lista de alunos
vem de planilha, as universidades são cadastradas à mão e a presença é
marcada pelo QR. A versão completa da feira internacional (inscrição pública
pelo site, painel de inscrições, palestras com presença e pesquisas de
satisfação) está arquivada em `arquivo-internacional/`.

## Como está organizado

- `index.html`: app dos representantes das universidades (ler o QR do aluno e salvar o contato). PWA com `sw.js` e `manifest.webmanifest`.
- `credenciamento.html`: mesa de entrada (ler o QR e marcar presença, busca por nome, cadastro avulso com crachá na hora).
- `evento.html`: painel ao vivo da direção, cadastro de universidades e gestão de usuários.
- `config.exemplo.js`: modelo do `config.js` com a URL e a chave anon do projeto. As três telas carregam `config.js` antes do supabase-js.
- `supabase/migrations/`: schema, RLS, funções e grants do banco (0001 a 0055, em ordem).
- `supabase/seeds/teste.sql`: alunos fictícios para testar os níveis de consentimento.
- `supabase/novo-evento-feira-local.sql`: roteiro de limpeza entre eventos (apaga dados de alunos e leads; leia os avisos no topo).
- `scripts/`: utilitários em Node sem dependências: importar alunos de planilha, criar contas de avaliadores, gerar crachás (alunos e representantes), QR de acesso para cartaz, listar alunos, exportar leads por universidade e montar a pasta de publicação. `scripts/chave.mjs` centraliza a leitura da service_role e da URL do projeto.
- `n8n/`: fluxos do n8n: envio do código OTP de login, envio do e-mail de confirmação de inscrição e ping diário para manter o projeto ativo.
- `docs/`: guias de operação (crachás e reimpressão, cadastro de avaliadores, tratamento de inscrições duplicadas).
- `requisitos-plataforma-avaliadores.md`: documento de requisitos e decisões técnicas.
- `arquivo-internacional/`: telas e scripts da feira internacional (inscrição, painel de inscrições, palestras, pesquisas de avaliação). O guia dessa versão é `arquivo-internacional/LEIAME-internacional.md`. Os scripts dessa pasta importam `chave.mjs` e `xlsx.mjs` de `scripts/`; para rodar, copie-os para `scripts/` ou ajuste o caminho do import.

## Stack

- Front: HTML, CSS e JavaScript puros, sem build. Bibliotecas por CDN: supabase-js, html5-qrcode, qrcode-generator.
- Banco: PostgreSQL, usando o Supabase como serviço gerenciado (Auth com login por código OTP, RLS, funções SQL e REST).
- Automação: n8n para e-mails (OTP e confirmação) e para o ping diário.
- Scripts de apoio: Node.js, sem pacotes externos (o leitor e gerador de planilhas está em `scripts/xlsx.mjs`).
- Hospedagem: Cloudflare Pages (arquivos estáticos, pasta `publicar/`).

## Como rodar

1. Crie um projeto no Supabase e rode as migrations de `supabase/migrations/` na ordem, de `0001` a `0055`, no SQL Editor.
2. Configure o login por código: em Authentication, ligue o provedor de e-mail com OTP e aponte o Send Email Hook para o webhook do fluxo `n8n/enviar-otp.json` (importe o JSON no n8n e conecte uma conta de e-mail).
3. Copie `config.exemplo.js` para `config.js` e preencha `SUPABASE_URL` e `SUPABASE_ANON_KEY` (Settings > API). O `config.js` fica fora do repositório.
4. Para os scripts, crie `segredo-supabase.txt` na raiz com a service_role (uma linha) ou defina `SUPABASE_SERVICE_ROLE` no ambiente. A URL do projeto vem do `config.js` ou da variável `SUPABASE_URL`.
5. Importe os alunos: `node scripts/importar-alunos.mjs alunos.xlsx` mostra o ensaio; acrescente `--executar` para gravar.
6. Cadastre as universidades em `evento.html` (Gestão de usuários, papel avaliador) ou em lote com `node scripts/criar-avaliadores.mjs universidades.csv` (CSV `nome,email,organizacao`).
7. Gere os crachás com `node scripts/gerar-crachas.mjs https://SEU-DOMINIO` (a URL vai dentro do QR). Os arquivos saem em `saida/`, que não é versionada.
8. Publique: `node scripts/preparar-deploy.mjs` monta a pasta `publicar/` (telas, `config.js`, service worker, manifest e ícones). Suba essa pasta no Cloudflare Pages. Depois de uma correção durante o evento, troque o nome do cache em `sw.js` para forçar a atualização nos celulares.

Nos fluxos do n8n, troque `https://SEU-PROJETO.supabase.co` e `COLE_AQUI_CHAVE_ANON` pelos valores do seu projeto. O fluxo de confirmação usa o código de `n8n/enviar-confirmacao.code.js` no nó "Montar e-mail".

Depois do evento, `node scripts/leads-avaliadores.mjs` gera uma planilha por universidade com os contatos que ela escaneou, em `saida/leads/`.

## Dados

Este repositório não contém dados pessoais. As planilhas de alunos, as listas de representantes, gestores e universidades, a pasta `saida/` (crachás e leads) e o arquivo com a service_role ficam fora por LGPD e por segurança, e estão no `.gitignore`.
