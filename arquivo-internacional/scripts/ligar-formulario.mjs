/* ============================================================
   Liga o formulário de inscrição ao Supabase

   O arquivo alfacem-international-university-fair.html é um
   bundle de 415 KB gerado por ferramenta externa. Editá-lo à mão
   é inviável, e qualquer reexportação apagaria a edição.

   Este script faz a ligação de forma repetível: extrai o template
   de dentro do bundle, aplica as alterações e reempacota. Se você
   reexportar o formulário, é só rodar de novo.

     node scripts/ligar-formulario.mjs

   Gera publicar/inscricao.html — o bundle original não é tocado.

   O QUE ELE ALTERA:

   1. Na etapa 5, `avancar()` deixa de só marcar `enviado: true` e
      passa a gravar no banco antes.
   2. Falha de envio aparece reaproveitando o binding errConsResp,
      que já é renderizado logo acima do botão. Sem isso, o erro
      seria invisível e o responsável acharia que inscreveu.
   3. O botão vira "Enviando…" durante a chamada.
   4. Nome do evento: o bundle foi exportado como "Alfa International
      University Fair" e o evento passou a se chamar "Career Day –
      Alfa University Fair". Troca as seis ocorrências no texto e o
      <title> da aba.

   Não usa supabase-js: uma chamada RPC é um POST com dois
   cabeçalhos. Carregar 40 KB de biblioteca para isso seria
   dependência sem motivo.
   ============================================================ */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const ORIGEM = 'alfacem-international-university-fair.html';

/* Escreve na raiz, não em publicar/ — o preparar-deploy.mjs apaga
   e recria publicar/ a cada execução, e levaria este arquivo junto.
   Ele copia inscricao.html da raiz, como faz com o index.html. */
const DESTINO = 'inscricao.html';

/* ---- termo de ciência (seção 17) ----

   CONTROLADOR é quem responde legalmente pelo tratamento. Se a
   entidade tem razão social diferente do nome de fachada, é a
   razão social que vale aqui.

   CONTATO_DADOS e RETENCAO estão SEM USO desde que o termo foi
   substituído pela redação jurídica: ela não traz prazo de
   retenção nem canal de revogação. Ficam aqui, e não apagados,
   porque a ausência dos dois está sinalizada e pode voltar — se
   voltar, é só reinserir os dois itens na lista da seção 17. */
const CONTATO_DADOS = 'direcao@exemplo.edu.br';   // sem uso
const RETENCAO      = '12 meses após a data do evento'; // sem uso
const CONTROLADOR   = 'Rede Alfacem Global Academy';

const SUPABASE_URL      = process.env.SUPABASE_URL      || 'https://SEU-PROJETO.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'SUA_CHAVE_ANON';

/* ---------------------------------------------------------- */

const bundle = readFileSync(ORIGEM, 'utf8');

const marcador = /(<script type="__bundler\/template">)([\s\S]*?)(<\/script>)/;
const achado = marcador.exec(bundle);
if (!achado) {
  console.error('Não encontrei o template dentro do bundle. O formato do arquivo mudou?');
  process.exit(1);
}

let tpl = JSON.parse(achado[2]);
const alteracoes = [];

function trocar(descricao, de, para) {
  if (!tpl.includes(de)) {
    console.error(`FALHOU: ${descricao}\n  trecho esperado não encontrado no formulário.`);
    process.exit(1);
  }
  tpl = tpl.replace(de, para);
  alteracoes.push(descricao);
}

/* Apaga do começo de `de` até o fim de `ate`. Existe para não
   precisar colar 2 KB de HTML dentro deste script só para deletá-lo.

   Confere as duas pontas e a ordem entre elas: se o formulário for
   reexportado com os blocos noutra sequência, para aqui em vez de
   recortar o pedaço errado do arquivo. */
function remover(descricao, de, ate) {
  const i = tpl.indexOf(de);
  const j = tpl.indexOf(ate);
  if (i < 0 || j < 0 || j < i) {
    console.error(`FALHOU: ${descricao}\n  marcadores não encontrados, ou fora de ordem.`);
    process.exit(1);
  }
  tpl = tpl.slice(0, i) + tpl.slice(j + ate.length);
  alteracoes.push(descricao);
}

/* Para trecho que se repete. O trocar() acima troca só a primeira
   ocorrência — silenciosamente, que é o pior jeito de errar. Este
   troca todas e diz quantas foram, para o número aparecer no log e
   você notar se mudar numa reexportação. */
function trocarTodas(descricao, de, para) {
  const quantas = tpl.split(de).length - 1;
  if (!quantas) {
    console.error(`FALHOU: ${descricao}\n  trecho esperado não encontrado no formulário.`);
    process.exit(1);
  }
  tpl = tpl.split(de).join(para);
  alteracoes.push(`${descricao} (${quantas}x)`);
}

/* ---- 1. estado novo ---- */
trocar(
  'estado: enviando / erroEnvio',
  "    passo: 1, enviado: false, tentou: false,",
  "    passo: 1, enviado: false, tentou: false, enviando: false, erroEnvio: '',"
);

/* ---- 2. envio de verdade na etapa 5 ---- */
trocar(
  'avancar(): grava no banco antes de confirmar',
  `    } else {
      this.setState({ enviado: true });
      const el = document.getElementById('inscricao');
      if (el) window.scrollTo({ top: el.offsetTop - 80, behavior: 'smooth' });
    }`,
  `    } else {
      this.enviar();
    }`
);

/* ---- 3. o método de envio ---- */
trocar(
  'método enviar()',
  '  voltar = () =>',
  `  enviar = async () => {
    if (this.state.enviando) return;
    this.setState({ enviando: true, erroEnvio: '' });

    const s = this.state;
    const dados = {
      nome:  s.nome.trim(),
      email: s.emailInst.trim().toLowerCase(),

      aluno_alfacem: s.alunoAlfa !== ALUNO_ALFA[1],
      colegio: s.alunoAlfa === ALUNO_ALFA[1] ? s.colegio.trim() : '',
      unidade: s.alunoAlfa === ALUNO_ALFA[1] ? '' : s.unidade,
      segmento: s.segmento,
      ano_escolaridade: s.ano,
      responsavel_acompanha: s.acomp,

      paises_interesse: s.paises,
      motivo: s.motivo,
      experiencia_internacional: s.exp,
      conhece_pathway: s.pathway,

      parentesco: s.parentesco,
      responsavel_nome: s.respNome.trim(),
      responsavel_email: s.email.trim().toLowerCase(),
      responsavel_telefone: s.respTel.trim(),

      // "Sim, autorizo" / "Não autorizo" -> booleano
      compartilhar_aluno: s.consAluno === SIM_NAO[0],
      compartilhar_responsavel: s.consResp === SIM_NAO[0],

      // O responsável preencheu a ficha, se identificou pelo grau
      // de parentesco e respondeu as autorizações. É a base legal
      // da inscrição — o aluno é menor de idade.
      consentimento_responsavel: true,

      // Termo de ciência: a marcação e o nome digitado como
      // confirmação. Precisa da migration 0010 no banco — sem ela
      // a função inscrever_aluno descarta os dois em silêncio.
      ciencia_compartilhamento: s.ciencia,
      assinatura_responsavel: s.assinatura.trim(),

      // Acompanhantes (migration 0012). Vai vazio quando o aluno
      // for sozinho. Os sem nome são descartados aqui e de novo
      // no banco — a família às vezes abre um bloco e desiste.
      acompanhantes: s.acomp === ACOMP[0] ? [] : s.acompanhantes
        .filter(p => p.nome.trim())
        .map(p => ({
          nome: p.nome.trim(),
          parentesco: p.parentesco,
          email: p.email.trim().toLowerCase(),
          telefone: p.telefone.trim()
        }))
    };

    const ERROS = {
      nome_obrigatorio: 'Preencha o nome completo do aluno.',
      responsavel_obrigatorio: 'Preencha o nome e o email do responsável.',
      email_invalido: 'O email do responsável não parece válido.',
      consentimento_obrigatorio: 'É necessário responder as autorizações.',
      ciencia_obrigatoria: 'É necessário marcar a ciência e autorização.',
      assinatura_obrigatoria: 'Digite o nome completo do responsável no fim do termo.',
      limite_de_acompanhantes: 'São no máximo 3 acompanhantes por aluno.',
      inscricao_duplicada: 'Já existe uma inscrição com estes dados. Se você não recebeu o e-mail de confirmação, procure na caixa de spam antes de enviar de novo — inscrever duas vezes gera dois crachás para a mesma pessoa.',
      limite_de_inscricoes: 'Já existem muitas inscrições com este email. Fale com a organização.',
      // Freio de inundação (migration 0013). A janela é de 10
      // minutos e libera sozinha, então a mensagem diz para
      // esperar em vez de mandar procurar a organização.
      muitas_tentativas: 'Muitas inscrições foram enviadas deste local nos últimos minutos. Aguarde alguns minutos e toque em Enviar novamente — nada do que você preencheu se perde.'
    };

    try {
      const r = await fetch('${SUPABASE_URL}/rest/v1/rpc/inscrever_aluno', {
        method: 'POST',
        headers: {
          'apikey': '${SUPABASE_ANON_KEY}',
          'Authorization': 'Bearer ${SUPABASE_ANON_KEY}',
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ p_dados: dados })
      });

      if (!r.ok) {
        const corpo = await r.text();
        let msg = 'Não foi possível enviar. Tente novamente em alguns instantes.';
        for (const chave in ERROS) if (corpo.indexOf(chave) >= 0) msg = ERROS[chave];
        throw new Error(msg);
      }

      this.setState({ enviado: true, enviando: false });
      const el = document.getElementById('inscricao');
      if (el) window.scrollTo({ top: el.offsetTop - 80, behavior: 'smooth' });
    } catch (err) {
      // Nunca marcar enviado: o responsável precisa saber que a
      // inscrição não foi gravada e poder tentar de novo.
      const semRede = !navigator.onLine || /failed to fetch|networkerror|load failed/i.test(err.message || '');
      this.setState({
        enviando: false,
        erroEnvio: semRede
          ? 'Sem conexão. Verifique a internet e toque em Enviar novamente.'
          : (err.message || 'Não foi possível enviar.')
      });
    }
  };

  voltar = () =>`
);

/* ---- 4. estado do botão durante o envio ----

   A falha de envio já teve outro tratamento aqui: era pendurada no
   binding errConsResp, que ficava logo acima do botão. Aquela
   pergunta saiu do formulário (seção 18) e o erro ganhou elemento
   próprio, dentro do termo — sem isso, falha de rede voltaria a
   ser invisível e o responsável acharia que inscreveu. */
trocar(
  'render: rótulo do botão durante o envio',
  "botaoLabel: s.passo === 5 ? 'Enviar inscrição' : 'Continuar',",
  "botaoLabel: s.enviando ? 'Enviando…' : (s.passo === 5 ? 'Enviar inscrição' : 'Continuar'),"
);

/* ---- 5. nome do evento ----

   "Alfa International University Fair" -> "Career Day – Alfa
   University Fair".

   O nome mudou de gênero junto: "a Fair" (feira) virou "o Career
   Day". Onde havia artigo ou preposição contraída antes do nome,
   a concordância vai junto — "Durante a" vira "Durante o", "na"
   vira "no". */

const NOME = 'Career Day – Alfa University Fair';

/* No H1 o nome é quebrado linha a linha: CAREER DAY / ALFA
   UNIVERSITY / FAIR, com "Fair" na cor de destaque.

   "ALFA UNIVERSITY" junto vira a linha mais longa do bloco — uns
   8,1 em de largura contra 5,5 em de "UNIVERSITY" sozinha. Em
   tela larga sobra espaço; em celular não, e o motivo está na
   resposta. */
trocar(
  'h1: nome do evento',
  'Alfa<br>International<br>University<br>',
  'Career Day<br>Alfa University<br>'
);

trocar(
  'texto de abertura: nome do evento',
  'do Alfa International University Fair,',
  `do ${NOME},`
);

trocar(
  'seção "durante o evento": nome do evento',
  'Durante a Alfa International University Fair,',
  `Durante o ${NOME},`
);

trocar(
  'orientações aos responsáveis: nome do evento',
  'seus filhos na Alfa International University Fair',
  `seus filhos no ${NOME}`
);

trocar(
  'etapa 4, pergunta do motivo: nome do evento',
  'de ir na International University Fair?',
  `de ir ao ${NOME}?`
);

trocar(
  'rodapé do formulário: nome do evento',
  'Alfa International University Fair · 22 de agosto',
  `${NOME} · 22 de agosto`
);

/* Erro de digitação do bundle original, na mesma frase do nome.
   Some na próxima reexportação se for corrigido na origem. */
trocar(
  'texto de abertura: "Edicação" -> "Edição"',
  '1ª Edicação',
  '1ª Edição'
);

/* ---- 6. velocidade da faixa de universidades ----

   São 45 universidades, ~15.000 px de conteúdo, percorridos em 42s:
   uns 360 px/s. Rápido demais para ler e desconfortável de olhar.
   150s deixa em ~100 px/s, que é velocidade de leitura.

   O `prefers-reduced-motion` vai junto porque quem sente tontura
   com movimento em tela costuma ter esse ajuste ligado no sistema.
   Precisa de !important: a animação está em atributo style e um
   seletor de classe sozinho não vence inline. */
trocar(
  'faixa de universidades: 42s -> 150s',
  '<div style="display:flex;width:max-content;animation:slide 42s linear infinite">',
  '<div class="mq" style="display:flex;width:max-content;animation:slide 150s linear infinite">'
);

trocar(
  'faixa de universidades: respeita prefers-reduced-motion',
  ':focus-visible{outline:2px solid var(--color-accent);outline-offset:2px}',
  ':focus-visible{outline:2px solid var(--color-accent);outline-offset:2px}\n@media (prefers-reduced-motion:reduce){.mq{animation:none !important}}'
);

/* ---- 7. nome do país ----

   Um lugar só: GRUPOS alimenta tanto o título da seção de
   universidades quanto a faixa que gira. A lista de países de
   interesse da etapa 4 já dizia "Reino Unido" — era a única
   divergência da página. */
trocar(
  "país: 'UK' -> 'Reino Unido'",
  "{ pais: 'UK', lista: [",
  "{ pais: 'Reino Unido', lista: ["
);

/* ---- 8. bandeiras na seção de universidades ----

   Desenhadas em SVG, não emoji. O Windows não tem glifo de
   bandeira: 🇧🇷 aparece como as duas letras "BR" na maior parte
   dos navegadores de lá, e boa parte das famílias vai abrir a
   página no Windows. SVG desenha igual em tudo.

   São vetores simplificados — no tamanho de unha em que aparecem,
   o que identifica o país é a combinação de cores, não o detalhe.
   A folha do Canadá e a cruz de Malta são aproximações.

   Todas em caixa 3:2, inclusive as que na vida real têm outra
   proporção (Suíça é quadrada, Reino Unido é 2:1). Fila de
   bandeiras com alturas diferentes fica torta. */
trocar(
  'bandeiras: desenhos SVG',
  'const GRUPOS = [',
  `const SVG_PAIS = {
  'Brasil': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="60" height="40" fill="#009b3a"/><path d="M30 4 56 20 30 36 4 20Z" fill="#fedf00"/><circle cx="30" cy="20" r="7.5" fill="#002776"/></svg>',
  'EUA': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="60" height="40" fill="#fff"/><g fill="#b22234"><rect y="0" width="60" height="3.08"/><rect y="6.15" width="60" height="3.08"/><rect y="12.31" width="60" height="3.08"/><rect y="18.46" width="60" height="3.08"/><rect y="24.62" width="60" height="3.08"/><rect y="30.77" width="60" height="3.08"/><rect y="36.92" width="60" height="3.08"/></g><rect width="24" height="21.54" fill="#3c3b6e"/></svg>',
  'França': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="20" height="40" fill="#002395"/><rect x="20" width="20" height="40" fill="#fff"/><rect x="40" width="20" height="40" fill="#ed2939"/></svg>',
  'Reino Unido': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="60" height="40" fill="#012169"/><path d="M0 0 60 40M60 0 0 40" fill="none" stroke="#fff" stroke-width="8"/><path d="M0 0 60 40M60 0 0 40" fill="none" stroke="#c8102e" stroke-width="4"/><path d="M30 0V40M0 20H60" fill="none" stroke="#fff" stroke-width="13"/><path d="M30 0V40M0 20H60" fill="none" stroke="#c8102e" stroke-width="8"/></svg>',
  'Canadá': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="60" height="40" fill="#fff"/><rect width="15" height="40" fill="#d52b1e"/><rect x="45" width="15" height="40" fill="#d52b1e"/><path d="M30 8 32 14 37 12 36 17 40 19 35 22 36 25 31 24 31.5 32 28.5 32 29 24 24 25 25 22 20 19 24 17 23 12 28 14Z" fill="#d52b1e"/></svg>',
  'Suíça': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="60" height="40" fill="#d52b1e"/><path d="M26.5 9h7v8h8v6h-8v8h-7v-8h-8v-6h8Z" fill="#fff"/></svg>',
  'Holanda': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="60" height="13.33" fill="#ae1c28"/><rect y="13.33" width="60" height="13.34" fill="#fff"/><rect y="26.67" width="60" height="13.33" fill="#21468b"/></svg>',
  'Irlanda': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="20" height="40" fill="#169b62"/><rect x="20" width="20" height="40" fill="#fff"/><rect x="40" width="20" height="40" fill="#ff883e"/></svg>',
  'Malta': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 40"><rect width="60" height="40" fill="#fff"/><rect x="30" width="30" height="40" fill="#c01120"/><path d="M9 5h5v5h5v5h-5v5H9v-5H4v-5h5Z" fill="#c9c9c9" stroke="#9c9c9c" stroke-width="0.8"/></svg>'
};

/* Vira data URI uma vez, na carga, e não a cada render. */
const BANDEIRA = {};
for (const p in SVG_PAIS) BANDEIRA[p] = 'data:image/svg+xml,' + encodeURIComponent(SVG_PAIS[p]);

const GRUPOS = [`
);

trocar(
  'bandeiras: expõe no paisesUni',
  `      paisesUni: GRUPOS.map((g, i) => ({
        pais: g.pais,`,
  `      paisesUni: GRUPOS.map((g, i) => ({
        pais: g.pais,
        bandeira: BANDEIRA[g.pais] || '',`
);

/* alt="" de propósito: o nome do país vem escrito ao lado, em
   seguida. Descrever a bandeira faria o leitor de tela dizer o
   país duas vezes.

   Sem align-self: o <img> alinha pela base junto com o texto, que
   é onde uma bandeira ao lado de um nome deve ficar. O box-shadow
   faz as vezes de contorno — sem ele, o lado branco da bandeira
   de Malta some no fundo. */
trocar(
  'bandeiras: <img> antes do nome do país',
  '<div style="display:flex;align-items:baseline;gap:14px">\n<span style="font:800 clamp(18px,2vw,26px)/1.1 var(--font-heading);letter-spacing:-0.01em;text-transform:uppercase">{{ g.pais }}</span>',
  '<div style="display:flex;align-items:baseline;gap:14px">\n<img src="{{ g.bandeira }}" alt="" width="30" height="20" style="width:clamp(22px,2.2vw,30px);height:auto;flex:none;box-shadow:0 0 0 1px rgba(0,0,0,.18)">\n<span style="font:800 clamp(18px,2vw,26px)/1.1 var(--font-heading);letter-spacing:-0.01em;text-transform:uppercase">{{ g.pais }}</span>'
);

/* ---- 9. prazo de inscrição ----

   É texto, não trava: a função inscrever_aluno não olha data
   nenhuma. Passado o dia 19 o formulário continua aceitando
   envio até alguém tirar a página do ar. */
trocar(
  'prazo de inscrição: 15 de junho -> 19 de agosto',
  'Formulário de interesse · até 15 de junho de 2026',
  'Formulário de interesse · até 19 de agosto de 2026'
);

/* ---- 10. observação no fim da lista de universidades ----

   Era cinza claro, 14px, peso 400, empurrada para o rodapé da
   seção por 60px de respiro — desenhada para passar despercebida.

   Vira uma faixa: fundo tonal, régua de 2px em cima como a que
   separa os países, corpo maior e mais pesado, e o "Obs.:" no
   vermelho da marca. Sem caixa alta.

   O respiro grande embaixo sai junto. Ele existia para afastar um
   texto acessório do fim da seção; numa faixa que fecha o bloco,
   viraria um vão de cor pendurado. */
/* "nesse" aponta para longe de quem fala; "neste" aponta para o
   que está diante. O evento é o desta página. */
trocar(
  'observação final: "nesse" -> "neste" evento',
  'presença nesse evento. A organização',
  'presença neste evento. A organização'
);

/* "A organização" vinha emendado no fim da frase, lendo como
   sujeito de uma oração que não existe — o verbo é que faltava.
   Com o fecho completo, ganha linha própria, corpo menor e peso
   normal: é assinatura, não continuação do aviso. */
trocar(
  'observação final: fecho da organização',
  ' neste evento. A organização</p>',
  ' neste evento.<span style="display:block;margin-top:12px;font:500 14px/1.4 var(--font-body);color:var(--color-accent-800)">A organização agradece a compreensão.</span></p>'
);

trocar(
  'observação final: mais destaque',
  '<p style="margin:0;padding:22px clamp(20px,4vw,56px) clamp(40px,5vw,64px);border-top:2px solid var(--color-divider);font:400 14px/1.6 var(--font-body);color:var(--color-neutral-700)">Obs.: Outras',
  '<p style="margin:0;padding:26px clamp(20px,4vw,56px);border-top:2px solid var(--color-text);background:var(--color-accent-100);font:600 clamp(15px,1.4vw,17px)/1.55 var(--font-body);color:var(--color-accent-900)"><strong style="font-weight:800;color:var(--brand-red)">Obs.:</strong> Outras'
);

/* ---- 11. concordância com o nome da escola ----

   "da alfacem global academy" -> "do alfacem global academy".

   As quatro ocorrências são a mesma construção, então uma troca só
   resolve todas. Uma delas está dentro de ALUNO_ALFA[0]; mexer no
   texto é seguro porque o código compara com ALUNO_ALFA[1], não
   com esse. */
trocarTodas(
  "escola: 'da alfacem' -> 'do alfacem'",
  'da alfacem global academy',
  'do alfacem global academy'
);

/* ---- 12. cascata unidade -> segmento -> ano ----

   Barra Aeronáutica só tem Anos Finais; Barra Américas só tem
   Ensino Médio. As outras seis unidades continuam oferecendo os
   dois — não foi dito nada sobre elas, e restringir por conta
   própria barraria inscrição legítima.

   O segmento, por sua vez, define os anos: Anos Finais leva ao 9º
   ano; Ensino Médio, às três séries.

   Quem estuda fora não escolhe unidade, então nada é filtrado
   para ele: os dois segmentos aparecem. */

trocar(
  'cascata: tabelas unidade->segmento e segmento->ano',
  "const ANOS = ['9º ano do Ensino Fundamental','1ª Série do Ensino Médio','2ª Série do Ensino Médio','3ª Série do Ensino Médio'];",
  `const ANOS = ['9º ano do Ensino Fundamental','1ª Série do Ensino Médio','2ª Série do Ensino Médio','3ª Série do Ensino Médio'];

/* Unidade que não está aqui oferece os dois segmentos. */
const SEGMENTO_DA_UNIDADE = {
  'Barra Aeronáutica': [SEGMENTOS[0]],
  'Barra Américas':    [SEGMENTOS[1]]
};

/* Montado a partir do ANOS para não repetir os textos: o 9º ano é
   o primeiro item, as três séries são o resto. */
const ANOS_DO_SEGMENTO = {
  [SEGMENTOS[0]]: ANOS.slice(0, 1),
  [SEGMENTOS[1]]: ANOS.slice(1)
};

function segmentosDe(unidade) { return SEGMENTO_DA_UNIDADE[unidade] || SEGMENTOS; }
function anosDe(segmento)     { return ANOS_DO_SEGMENTO[segmento]   || ANOS; }`
);

trocar(
  'cascata: limpeza do que fica inválido',
  `  radio(key, list) {
    return list.map(label => ({
      label, on: this.state[key] === label,
      pick: () => this.setState({ [key]: label })
    }));
  }`,
  `  radio(key, list) {
    return list.map(label => ({
      label, on: this.state[key] === label,
      pick: () => this.setState({ [key]: label })
    }));
  }

  /* Igual ao radio acima, mas com um pick próprio — para as
     escolhas que arrastam as de baixo junto. */
  radioCom(key, list, pick) {
    return list.map(label => ({
      label, on: this.state[key] === label,
      pick: () => pick(label)
    }));
  }

  /* Filtrar a lista esconde o botão, mas não apaga o que já foi
     marcado. Sem esta limpeza, quem escolhesse "3ª Série" e depois
     voltasse para marcar "Barra Aeronáutica" enviaria a combinação
     Aeronáutica + 3ª Série — que não existe — com a tela mostrando
     um formulário aparentemente correto. */
  escolherUnidade = (unidade) => this.setState(s => {
    const segmento = segmentosDe(unidade).indexOf(s.segmento) > -1 ? s.segmento : '';
    const ano = segmento && anosDe(segmento).indexOf(s.ano) > -1 ? s.ano : '';
    return { unidade, segmento, ano };
  });

  escolherSegmento = (segmento) => this.setState(s => ({
    segmento,
    ano: anosDe(segmento).indexOf(s.ano) > -1 ? s.ano : ''
  }));`
);

trocar(
  'cascata: listas filtradas na tela',
  `      unidadeOpts: this.radio('unidade', UNIDADES),
      segmentoOpts: this.radio('segmento', SEGMENTOS),
      anoOpts: this.radio('ano', ANOS),`,
  `      unidadeOpts: this.radioCom('unidade', UNIDADES, this.escolherUnidade),
      /* A unidade só filtra se o aluno for da rede. Quem marcou
         "estuda em outro colégio" depois de já ter escolhido uma
         unidade continua com o valor no estado, e ele não pode
         mandar em nada — o campo nem aparece mais. */
      segmentoOpts: this.radioCom(
        'segmento',
        segmentosDe(s.alunoAlfa === ALUNO_ALFA[1] ? '' : s.unidade),
        this.escolherSegmento
      ),
      anoOpts: this.radio('ano', anosDe(s.segmento)),`
);

/* ---- 13. "seu filho(a)" -> "aluno" ----

   Três construções, três trocas. Uma troca literal de
   "seu filho(a)" por "aluno" deixaria "Em qual instituição de
   ensino aluno estuda?" — o artigo precisa entrar junto.

   A ordem importa: "do seu filho(a)" sai primeiro, senão a regra
   de baixo transformaria em "do o aluno". */

trocarTodas(
  '"do seu filho(a)" -> "do aluno"',
  'do seu filho(a)',
  'do aluno'
);

/* Começo de frase. */
trocarTodas(
  '"Seu filho(a)" -> "O aluno"',
  'Seu filho(a)',
  'O aluno'
);

/* O que sobrou está no meio da frase. */
trocarTodas(
  '"seu filho(a)" -> "o aluno"',
  'seu filho(a)',
  'o aluno'
);

/* ---- 14. voz: quem responde é o responsável ----

   O formulário foi escrito como se o aluno respondesse — "sou
   aluno", "meu responsável irá me acompanhar", "já morei fora com
   a minha família". Quem preenche é o responsável, então as
   respostas ficavam falando de outra pessoa que não a que está na
   tela. Depois que as perguntas viraram "o aluno...", o descompasso
   ficou explícito: pergunta na terceira pessoa, resposta na
   primeira.

   Tudo passa para a terceira pessoa, falando do aluno.

   Seguro mexer nesses textos: o código compara com ALUNO_ALFA[1],
   o próprio elemento do array, nunca com a string escrita à mão.
   ACOMP, MOTIVOS e EXPS não são comparados em lugar nenhum — só
   listados e gravados. */

trocar(
  'etapa 1: pergunta do colégio',
  '>Você é aluno do alfacem global academy? <',
  '>O aluno estuda no alfacem global academy? <'
);

trocar(
  'etapa 1: respostas do colégio',
  "const ALUNO_ALFA = ['Sim, sou aluno do alfacem global academy','Não, estudo em outro colégio'];",
  "const ALUNO_ALFA = ['Sim, estuda no alfacem global academy','Não, estuda em outro colégio'];"
);

/* Era a resposta do print: pergunta "O aluno irá sozinho ou
   acompanhado", resposta "Meu responsável irá me acompanhar". */
trocar(
  'etapa 3: respostas do acompanhante',
  "const ACOMP = ['Sozinho','Meu responsável irá me acompanhar'];",
  "const ACOMP = ['Sozinho','Acompanhado do responsável'];"
);

/* "Tenho Interesse" tinha maiúscula no meio da frase. */
trocar(
  'etapa 4: respostas do motivo',
  "const MOTIVOS = ['Não conheço nada sobre o assunto de aplicação internacional e quero entender','Conheço um pouco sobre o assunto, mas não tenho interesse de aplicar para uma universidade no exterior','Tenho Interesse em aplicar para uma universidade no exterior'];",
  "const MOTIVOS = ['Não conhece nada sobre o assunto de aplicação internacional e quer entender','Conhece um pouco sobre o assunto, mas não tem interesse de aplicar para uma universidade no exterior','Tem interesse em aplicar para uma universidade no exterior'];"
);

/* "com a minha família" vira "com a família": a família é a de
   quem preenche, não precisa do possessivo. */
trocar(
  'etapa 4: respostas da experiência internacional',
  "const EXPS = ['Sim, já viajei para fora a passeio','Sim, já fiz um programa de intercâmbio','Sim, já morei fora com a minha família','Não, nunca saí do Brasil'];",
  "const EXPS = ['Sim, já viajou para fora a passeio','Sim, já fez um programa de intercâmbio','Sim, já morou fora com a família','Não, nunca saiu do Brasil'];"
);

/* O responsável não está se inscrevendo — está inscrevendo o
   aluno. */
trocar(
  'botão do topo: "minha inscrição"',
  '>Fazer minha inscrição',
  '>Fazer a inscrição'
);

/* ---- 15. países de interesse ----

   A página anuncia universidades de 9 países, mas quatro deles não
   existiam como resposta: Suíça, Holanda, Irlanda e Malta. Quem se
   interessasse por eles só tinha "Outro" — e o representante que
   viajou para cá não conseguiria achar esse aluno.

   "EUA" na lista de universidades e "Estados Unidos" na lista de
   respostas são o mesmo país com rótulos diferentes; esse já
   estava coberto.

   Portugal, Itália e Alemanha ficam, mesmo sem universidade
   presente: a pergunta é sobre interesse, não sobre quem veio.

   Entram antes de "Outro", que precisa continuar sendo o último.

   O nome do país na seção de universidades estava sem acento
   ("Suiça"). Agora que "Suíça" aparece escrito certo como opção de
   resposta, os dois estariam na mesma página grafados de formas
   diferentes — daí a correção junto. A chave do SVG_PAIS foi
   ajustada no bloco das bandeiras, senão a bandeira sumiria. */

trocar(
  'países de interesse: + Suíça, Holanda, Irlanda, Malta',
  "const PAISES = ['Estados Unidos','Canadá','Portugal','Itália','França','Alemanha','Reino Unido','Outro'];",
  "const PAISES = ['Estados Unidos','Canadá','Portugal','Itália','França','Alemanha','Reino Unido','Suíça','Holanda','Irlanda','Malta','Outro'];"
);

trocar(
  "seção de universidades: 'Suiça' -> 'Suíça'",
  "{ pais: 'Suiça', lista: [['LES ROCHES / GLION / ECOLE DUCASSE','BIANCA CURVELLO']] },",
  "{ pais: 'Suíça', lista: [['LES ROCHES / GLION / ECOLE DUCASSE','BIANCA CURVELLO']] },"
);

/* ---- 16. nome do programa ----

   A pergunta trazia o nome da escola no lugar do nome do programa.
   O banco sempre soube: a coluna chama conhece_pathway.

   São dois lugares — a pergunta na etapa 4 e a linha do resumo na
   tela de confirmação, que exibia só "alfacem global academy" sem
   dizer o que estava perguntando ali.

   Minúsculas seguindo a grafia do resto da página, que escreve
   "alfacem global academy" assim até no meio da frase. Na
   pergunta o CSS deixa tudo em caixa alta de qualquer forma; no
   resumo é que aparece como está escrito aqui. */

trocar(
  'etapa 4: nome do programa na pergunta',
  '>Você conhece o programa alfacem global academy? <',
  '>Você conhece o programa alfa global pathway? <'
);

trocar(
  'resumo: nome do programa',
  "{ q: 'alfacem global academy', a: s.pathway || '—' },",
  "{ q: 'Conhece o alfa global pathway', a: s.pathway || '—' },"
);

/* ---- 17. termo de ciência e autorização ----

   As duas perguntas que já existiam registram a DECISÃO ("autorizo"
   / "não autorizo"), mas não registram sobre o quê a pessoa
   concordou, nem que quem clicou era o responsável legal. É a
   lacuna que o preparar-deploy.mjs vinha avisando a cada execução:
   nenhuma menção a finalidade, retenção, revogação ou controlador.

   O termo entra no fim da etapa 5, com três partes: o texto, a
   caixa de ciência e o nome digitado como confirmação.

   O nome é pedido de novo, mesmo já tendo sido preenchido na etapa
   1. Não é redundância: na etapa 1 ele é dado cadastral, aqui é o
   ato de assinar. Digitar o próprio nome embaixo de um texto que
   se acabou de ler é o que transforma um clique em declaração.

   Guardar isso exige a migration 0010 — sem ela a função
   inscrever_aluno ignora os dois campos e o termo vira enfeite. */

trocarTodas(
  'termo: estado (state e reiniciar)',
  "consAluno: '', consResp: ''",
  "consAluno: '', consResp: '', ciencia: false, assinatura: ''"
);

trocar(
  'termo: alternar a caixa de ciência',
  `  escolherSegmento = (segmento) => this.setState(s => ({`,
  `  alternarCiencia = () => this.setState(s => ({ ciencia: !s.ciencia }));

  escolherSegmento = (segmento) => this.setState(s => ({`
);

/* Sobrenome exigido: "Maria" sozinho não identifica ninguém, e o
   campo existe justamente para identificar quem assinou. */
trocar(
  'termo: validação',
  "      if (!s.consAluno) e.consAluno = 'Resposta obrigatória: escolha sim ou não.';",
  `      if (!s.ciencia) e.ciencia = 'É necessário marcar que você tem ciência e autoriza.';
      if (!s.assinatura.trim()) e.assinatura = 'Digite o nome completo do responsável.';
      else if (s.assinatura.trim().split(/\\s+/).length < 2) e.assinatura = 'Digite o nome completo, com sobrenome.';
      if (!s.consAluno) e.consAluno = 'Resposta obrigatória: escolha sim ou não.';`
);

/* Ancorado nos erros da etapa 2, que ficam onde estão. Os da
   etapa 5 saem na seção 18 e não servem de referência. */
trocar(
  'termo: valores para a tela',
  "errUnidade: e.unidade || '', errSegmento: e.segmento || '', errAno: e.ano || '',",
  `errUnidade: e.unidade || '', errSegmento: e.segmento || '', errAno: e.ano || '',
      cienciaOn: s.ciencia, cienciaPick: this.alternarCiencia,
      errCiencia: e.ciencia || '',
      assinatura: s.assinatura, setAssinatura: this.set('assinatura'),
      errAssinatura: e.assinatura || '',
      erroEnvio: s.erroEnvio,`
);

trocar(
  'termo: linhas no resumo',
  `      { q: 'Compartilhar contato do responsável', a: s.consResp || '—' }
    ];`,
  `      { q: 'Compartilhar contato do responsável', a: s.consResp || '—' },
      { q: 'Ciência e autorização', a: s.ciencia ? 'Sim, tenho ciência e autorizo' : '—' },
      { q: 'Assinado por', a: s.assinatura || '—' }
    ];`
);

/* O texto. Caixa com borda de 2px, que na página é o que marca
   documento — o resto da etapa usa fundo tonal para aviso. */
trocar(
  'termo: o texto na tela',
  `<sc-if value="{{ errConsResp }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errConsResp }}</span></sc-if>
</div>
</div>
</sc-if>`,
  `<sc-if value="{{ errConsResp }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errConsResp }}</span></sc-if>
</div>

<div style="display:flex;flex-direction:column;gap:18px;padding:clamp(20px,3vw,28px);border:2px solid var(--color-text);background:#fff">
<div style="display:flex;flex-direction:column;gap:8px">
<div style="font:600 11px/1.5 var(--font-heading);letter-spacing:.16em;text-transform:uppercase;color:var(--brand-red)">Career Day · Alfa University Fair</div>
<div style="font:800 clamp(18px,2vw,22px)/1.2 var(--font-heading);letter-spacing:-0.01em;color:var(--color-text)">Termo de Ciência e Autorização</div>
<div style="font:400 14px/1.5 var(--font-body);color:var(--color-neutral-700)">Compartilhamento de dados do responsável e do aluno com as instituições participantes.</div>
</div>
<p style="margin:0;font:400 15px/1.66 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Declaro, para os devidos fins, que sou o responsável legal pelo aluno indicado nesta inscrição e que sou eu quem está preenchendo este formulário.</p>
<p style="margin:0;font:400 15px/1.66 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Declaro, ainda, sob minha inteira responsabilidade, que todas as informações aqui prestadas — tanto as minhas quanto as do aluno, que é menor de idade — são verdadeiras, completas e exatas, respondendo civil e legalmente por sua veracidade.</p>
<p style="margin:0;font:400 15px/1.66 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Tenho ciência de que os dados informados neste formulário serão coletados e tratados pela ${CONTROLADOR}, na condição de controladora, e compartilhados com as universidades e instituições de ensino participantes do ${NOME}, autorizando expressamente esse compartilhamento na qualidade de responsável legal pelo menor.</p>
<p style="margin:0;font:400 15px/1.66 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Este tratamento de dados observa a Lei nº 13.709/2018 (Lei Geral de Proteção de Dados Pessoais – LGPD) e as demais normas aplicáveis, sendo realizado com as seguintes características:</p>
<ul style="margin:0;padding-left:20px;display:flex;flex-direction:column;gap:12px;font:400 15px/1.6 var(--font-body);color:var(--color-neutral-900)">
<li><strong>Finalidade:</strong> organizar o evento, emitir o crachá do aluno e permitir que as instituições participantes entrem em contato com o responsável e/ou com o aluno para apresentar informações sobre programas, processos de aplicação, bolsas e oportunidades de estudo, não sendo os dados utilizados para qualquer finalidade diversa das aqui descritas.</li>
<li><strong>Base legal e consentimento:</strong> manifesto meu consentimento livre, informado e inequívoco para o tratamento e o compartilhamento dos dados nos termos acima, na forma prevista na LGPD, ciente de que, por se tratar de dados de menor de idade, o consentimento é prestado por mim, no melhor interesse da criança ou do adolescente.</li>
</ul>
<p style="margin:0;font:600 15px/1.6 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Ao confirmar, declaro que li, compreendi e concordo integralmente com os termos deste documento.</p>
</div>

<div style="display:flex;flex-direction:column;gap:14px">
<button class="opt" type="button" role="checkbox" aria-checked="{{ cienciaOn }}" sc-camel-on-click="{{ cienciaPick }}" style="display:flex;align-items:flex-start;gap:13px;padding:18px 18px;background:#fff;border:2px solid var(--color-neutral-300);color:var(--color-text);font:500 16px/1.35 var(--font-body);text-align:left;cursor:pointer">
<span class="mk" style="width:13px;height:13px;flex:none;margin-top:4px;border:2px solid var(--color-neutral-400)"></span>Sim, tenho ciência e autorizo o compartilhamento dos dados nos termos acima.</button>
<sc-if value="{{ errCiencia }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errCiencia }}</span></sc-if>
</div>

<div style="display:flex;flex-direction:column;gap:14px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Nome completo do responsável, para confirmar <span style="color:var(--brand-red)">*</span></label>
<input class="inp" type="text" placeholder="Digite seu nome completo" value="{{ assinatura }}" sc-camel-on-change="{{ setAssinatura }}">
<sc-if value="{{ errAssinatura }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errAssinatura }}</span></sc-if>
</div>

<sc-if value="{{ erroEnvio }}" hint-placeholder-val="{{ false }}"><p style="margin:0;padding:16px 18px;border:2px solid var(--brand-red);background:#fff;font:500 15px/1.5 var(--font-body);color:var(--brand-red)">{{ erroEnvio }}</p></sc-if>
</div>
</sc-if>`
);

/* ---- 18. saem as duas perguntas de autorização ----

   "Você autoriza o compartilhamento dos dados de contato do
   aluno?" e a equivalente para o responsável. O termo da seção 17
   passou a dizer a mesma coisa de forma mais completa, e as duas
   viraram repetição — a pessoa autorizava três vezes na mesma
   tela.

   MUDA O SENTIDO DO FORMULÁRIO, não só o layout: antes dava para
   se inscrever recusando o compartilhamento. Agora o termo é
   condição da inscrição, e quem não concorda não se inscreve.
   Está anotado em detalhe na resposta; não é decisão de código.

   Com as perguntas fora, o compartilhamento passa a vir da caixa
   de ciência, que é obrigatória — na prática, sempre verdadeiro. */

remover(
  'etapa 5: tira as duas perguntas de autorização',
  '<div style="display:flex;flex-direction:column;gap:14px">\n<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Você autoriza o compartilhamento dos dados de contato do aluno',
  '{{ errConsResp }}</span></sc-if>\n</div>\n'
);

/* Duas ocorrências: o state inicial e o reiniciar(). Deixar só uma
   guardaria campo morto que o "fazer outra inscrição" nunca limpa. */
trocarTodas(
  'etapa 5: tira consAluno/consResp do estado',
  "consAluno: '', consResp: '', ciencia: false, assinatura: ''",
  "ciencia: false, assinatura: ''"
);

/* Só existia para as duas perguntas que saíram. */
trocar(
  'etapa 5: tira a lista SIM_NAO, agora sem uso',
  "const SIM_NAO = ['Sim, autorizo','Não autorizo'];\n",
  ''
);

trocar(
  'etapa 5: tira a validação das duas perguntas',
  `      if (!s.consAluno) e.consAluno = 'Resposta obrigatória: escolha sim ou não.';
      if (!s.consResp) e.consResp = 'Resposta obrigatória: escolha sim ou não.';`,
  ''
);

trocar(
  'etapa 5: tira os valores das duas perguntas da tela',
  "      errConsAluno: e.consAluno || '', errConsResp: e.consResp || '',\n",
  ''
);

trocar(
  'etapa 5: tira as listas de opções',
  `      consAlunoOpts: this.radio('consAluno', SIM_NAO),
      consRespOpts: this.radio('consResp', SIM_NAO),\n`,
  ''
);

trocar(
  'etapa 5: tira as duas linhas do resumo',
  `      { q: 'Compartilhar contato do aluno', a: s.consAluno || '—' },
      { q: 'Compartilhar contato do responsável', a: s.consResp || '—' },\n`,
  ''
);

/* O compartilhamento passa a sair da ciência. A migration exige
   ciencia_compartilhamento = true, então os dois chegam sempre
   true no banco — mas escrever s.ciencia, e não true literal,
   mantém a origem do dado visível: se um dia a ciência deixar de
   ser obrigatória, o compartilhamento acompanha sozinho. */
trocar(
  'envio: compartilhamento vem da ciência',
  `      compartilhar_aluno: s.consAluno === SIM_NAO[0],
      compartilhar_responsavel: s.consResp === SIM_NAO[0],`,
  `      compartilhar_aluno: s.ciencia,
      compartilhar_responsavel: s.ciencia,`
);

/* ---- 19. sai a recepção aos representantes ----

   Bloco "Exclusivo · por convite / Recepção aos Representantes das
   Universidades", das 12h20 às 14h20.

   É um <section> inteiro e fechado em si mesmo, sem id — nenhum
   link do menu apontava para ele, então nada fica órfão. Os dois
   marcadores abaixo são únicos e a ordem entre eles é conferida:
   se o formulário voltar reexportado com o bloco noutro lugar, o
   script para em vez de recortar o pedaço errado. */
remover(
  'página: tira a seção da recepção aos representantes',
  '<section class="rv" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));border-bottom:2px solid var(--color-text)">',
  '2 horas · mesmo local</span>\n</div>\n</section>\n\n'
);

/* ---- 20. caixa dos nomes próprios ----

   O bundle escrevia o nome da instituição todo em minúsculas.
   Onde o CSS aplica caixa alta ninguém percebia; onde não aplica —
   o rodapé "alfacem global academy · Américas", os parágrafos de
   abertura, o termo — aparecia minúsculo mesmo.

   A troca cobre as 13 ocorrências de uma vez, inclusive os três
   alt="" dos logos, que é o nome que o leitor de tela anuncia.
   Ninguém quer ouvir a instituição soletrada em minúsculas.

   O e-mail alfacem.com.br não é afetado: a troca casa a frase
   inteira, não a palavra solta.

   O nome do programa vinha do mesmo lugar — eu tinha escrito em
   minúsculas seguindo a grafia que o bundle usava. Vai junto. */

trocarTodas(
  'nome da instituição: caixa correta',
  'alfacem global academy',
  'Alfacem Global Academy'
);

trocarTodas(
  'nome do programa: caixa correta',
  'alfa global pathway',
  'Alfa Global Pathway'
);

/* ---- 21. saem os números institucionais ----

   Bloco "Educação que forma, inspira e transforma / Referência em
   excelência no Rio de Janeiro desde 1994", com ENEM, SAT, TOEFL
   e medalhas.

   Outro <section> fechado em si mesmo e sem id — nada aponta para
   ele.

   O array que alimentava os quatro números sai junto. Deixá-lo
   viraria dado órfão: ninguém lembra por que existe, e daqui a
   dois anos alguém atualiza o SAT achando que aparece em algum
   lugar. */

remover(
  'página: tira a seção dos números institucionais',
  '<section class="rv" style="padding:clamp(40px,5vw,76px) clamp(20px,4vw,56px);background:#fff;border-bottom:2px solid var(--color-text)">',
  '{{ n.l }}</span>\n</div>\n</sc-for>\n</div>\n</section>\n\n'
);

trocar(
  'página: tira o array dos números, agora sem uso',
  `      numeros: [
        { v: '1º', l: 'ENEM 2024 · Rio de Janeiro' },
        { v: '1.430', l: 'Média de pontuação SAT' },
        { v: '106', l: 'Média de pontuação TOEFL' },
        { v: '3.000+', l: 'Medalhas em olimpíadas nac. e int.' }
      ],\n`,
  ''
);

/* ---- 22. logo deitada no painel do topo ----

   O painel usava a versão empilhada (286x520). Girar por CSS não
   resolveria: deitaria o texto junto e a marca ficaria de lado.
   Logo horizontal é outro arquivo.

   O bundle já traz um: 4454cd36, 838x244, a mesma que está no
   menu do topo. Reaproveitar não acrescenta um byte ao arquivo —
   ela já viaja no bundle de qualquer jeito.

   O max-width sobe de 180px para 419px. A empilhada em 180px de
   largura dava 327px de altura; a deitada nos mesmos 180px daria
   52px, e sumiria dentro do painel.

   419px não é número redondo à toa: o PNG tem 838px de largura
   real, e tela de densidade dupla — todo celular e todo notebook
   recente — pede o dobro de pixels do que ocupa. 838 / 2 = 419 é
   o maior tamanho em que a logo ainda é desenhada com pixel de
   sobra. Passar disso começa a esticar imagem, e a marca aparece
   levemente borrada justo no ponto mais visível da página.

   Para ficar maior que isso sem perder nitidez, precisa de um
   arquivo maior ou de um SVG. */
trocar(
  'topo: logo horizontal no lugar da empilhada',
  '<img src="6db551b4-23c6-4819-a238-f1fb7aa57522" alt="Alfacem Global Academy" style="width:100%;max-width:180px;height:auto;display:block">',
  '<img src="4454cd36-17d1-4268-97ce-328320013a0f" alt="Alfacem Global Academy" style="width:100%;max-width:419px;height:auto;display:block">'
);

/* ---- 23. aluno de outro colégio ----

   INTERRUPTOR: true libera a inscrição de aluno externo, false
   deixa a opção na tela, cinza e sem resposta ao clique.

   Inscrição externa abre e fecha por data, então isto é uma
   constante e não uma seção para apagar: apagar obrigaria a
   reescrever o bloqueio na hora de fechar de novo, que é
   justamente quando não se quer estar mexendo em código.

   Nada mais depende disto. O campo "em qual instituição de ensino
   o aluno estuda?" e a regra que libera os dois segmentos estão
   sempre no lugar — com o interruptor em false eles só ficam
   inalcançáveis.

   O bloqueio é feito por aria-disabled e não pelo atributo
   disabled: disabled é booleano em HTML, e "disabled=false"
   desativa o botão do mesmo jeito que "disabled=true" — a opção
   certa ficaria morta junto. aria-disabled recebe true/false como
   texto e se comporta como o esperado, além de ser o que o leitor
   de tela anuncia.

   O clique também é neutralizado no JS. Estilo sozinho não impede
   nada: bastaria o teclado, ou o próprio toque, para marcar uma
   opção que a tela diz estar desligada. */

const EXTERNO_LIBERADO = true;

if (EXTERNO_LIBERADO) {
  console.log('Inscrição de aluno externo: LIBERADA.');
} else {

trocar(
  'externo: aparência de desativado',
  '@media (prefers-reduced-motion:reduce){.mq{animation:none !important}}',
  `@media (prefers-reduced-motion:reduce){.mq{animation:none !important}}
.opt[aria-disabled="true"]{background:var(--color-neutral-100) !important;border-color:var(--color-neutral-200) !important;color:var(--color-neutral-500) !important;cursor:not-allowed}
.opt[aria-disabled="true"]:hover{border-color:var(--color-neutral-200) !important}
.opt[aria-disabled="true"] .mk{background:transparent !important;border-color:var(--color-neutral-300) !important}`
);

trocar(
  'externo: marca o botão na tela',
  'list="{{ alunoAlfaOpts }}" as="o" hint-placeholder-count="2">\n<button class="opt" type="button" role="radio" aria-checked="{{ o.on }}"',
  'list="{{ alunoAlfaOpts }}" as="o" hint-placeholder-count="2">\n<button class="opt" type="button" role="radio" aria-checked="{{ o.on }}" aria-disabled="{{ o.bloqueada }}"'
);

trocar(
  'externo: clique sem efeito',
  "      alunoAlfaOpts: this.radio('alunoAlfa', ALUNO_ALFA),",
  `      alunoAlfaOpts: ALUNO_ALFA.map(label => {
        const bloqueada = label === ALUNO_ALFA[1];
        return {
          label,
          bloqueada,
          on: s.alunoAlfa === label,
          pick: bloqueada ? (() => {}) : (() => this.setState({ alunoAlfa: label }))
        };
      }),`
);

console.log('Inscrição de aluno externo: BLOQUEADA na tela.');
}

/* ---- 24. "Rede" no nome da instituição ----

   "Alfacem Global Academy" -> "Rede Alfacem Global Academy".

   "Rede" é feminino, e isso desfaz a concordância da seção 11.
   Lá o nome era tratado como masculino ("do Alfacem"); com Rede
   na frente volta a ser feminino ("da Rede Alfacem").

   O prefixo entra PRIMEIRO e a concordância depois. Na ordem
   inversa dava errado duas vezes:

   - "do Alfacem" -> "da Rede Alfacem" antes da troca geral, e
     depois a troca geral acharia "Alfacem Global Academy" dentro
     do que ela mesma produziu: "da Rede Rede Alfacem...".
   - pior, "no Alfacem" casa dentro de "Alu-no Alfacem", e a
     linha do resumo viraria "Aluna Rede Alfacem Global Academy".

   Com o prefixo antes, as duas correções passam a procurar
   "Rede Alfacem", que não aparece por acidente em lugar nenhum. */

/* Prefixo idempotente. O CONTROLADOR do termo já vem escrito por
   extenso lá no topo deste arquivo, e um replace cego produziria
   "Rede Rede Alfacem Global Academy" — aconteceu. O (Rede )?
   consome o prefixo existente e reescreve por cima, então rodar
   de novo não empilha nada. */
{
  const quantas = (tpl.match(/(Rede )?Alfacem Global Academy/g) || []).length;
  if (!quantas) {
    console.error('FALHOU: nome: prefixo "Rede"\n  nome da instituição não encontrado.');
    process.exit(1);
  }
  tpl = tpl.replace(/(Rede )?Alfacem Global Academy/g, 'Rede Alfacem Global Academy');
  alteracoes.push(`nome: prefixo "Rede" (${quantas}x)`);
}

trocarTodas(
  'nome: "do Rede" -> "da Rede"',
  ' do Rede Alfacem Global Academy',
  ' da Rede Alfacem Global Academy'
);

trocarTodas(
  'nome: "no Rede" -> "na Rede"',
  ' no Rede Alfacem Global Academy',
  ' na Rede Alfacem Global Academy'
);

/* Rótulo telegráfico do resumo: "Aluno Rede Alfacem Global
   Academy?" não se lê. O "da" resolve. */
trocar(
  'nome: linha do resumo',
  "{ q: 'Aluno Rede Alfacem Global Academy?', a: s.alunoAlfa }",
  "{ q: 'Aluno da Rede Alfacem Global Academy?', a: s.alunoAlfa }"
);

/* ---- 25. acompanhantes ----

   Todo mundo que entra no evento precisa de crachá. Marcando
   "acompanhado", a etapa 3 abre os mesmos campos da etapa 1 —
   nome, parentesco, e-mail, telefone — para até 3 pessoas.

   O primeiro bloco vem preenchido com os dados de quem está
   preenchendo, e só quando ainda está em branco. Na maioria dos
   casos é a mesma pessoa, e obrigar a redigitar nome, e-mail e
   telefone que ela acabou de informar duas telas antes é atrito
   sem motivo. Continua editável: quem preenche pode não ser quem
   vai.

   Nome e parentesco são obrigatórios; e-mail e telefone não. O
   crachá precisa do nome, e cobrar e-mail de uma avó que vai só
   acompanhar barraria inscrição por nada.

   Ninguém vê esses dados no app: o QR do crachá do acompanhante
   é o token do aluno. São da organização, para o crachá e para
   contato sobre o evento. */

trocarTodas(
  'acompanhantes: estado (state e reiniciar)',
  "ciencia: false, assinatura: ''",
  "ciencia: false, assinatura: '', acompanhantes: []"
);

trocar(
  'acompanhantes: adicionar, remover e preencher',
  '  alternarCiencia = () => this.setState(s => ({ ciencia: !s.ciencia }));',
  `  acompVazio = () => ({ nome: '', parentesco: '', email: '', telefone: '' });

  /* Marcar "acompanhado" abre o primeiro bloco já com os dados de
     quem preencheu. Só quando a lista está vazia: se a pessoa
     marcar sozinho, voltar atrás e marcar acompanhado de novo,
     não sobrescreve o que ela já tinha digitado. */
  escolherAcomp = (acomp) => this.setState(s => {
    if (acomp === ACOMP[0]) return { acomp };
    if (s.acompanhantes.length) return { acomp };
    return {
      acomp,
      acompanhantes: [{
        nome: s.respNome,
        parentesco: s.parentesco,
        email: s.email,
        telefone: s.respTel
      }]
    };
  });

  adicionarAcomp = () => this.setState(s =>
    s.acompanhantes.length >= 3 ? {} :
    ({ acompanhantes: s.acompanhantes.concat([this.acompVazio()]) }));

  removerAcomp = (i) => () => this.setState(s =>
    ({ acompanhantes: s.acompanhantes.filter((_, j) => j !== i) }));

  editarAcomp = (i, campo) => (e) => {
    const valor = e.target.value;
    this.setState(s => ({
      acompanhantes: s.acompanhantes.map((p, j) =>
        j === i ? Object.assign({}, p, { [campo]: valor }) : p)
    }));
  };

  alternarCiencia = () => this.setState(s => ({ ciencia: !s.ciencia }));`
);

/* A validação só cobra o que o crachá precisa. O bloco em branco
   é ignorado aqui e descartado no envio — mas se sobrar UM só, e
   vazio, a pessoa disse que vem acompanhada e não informou
   ninguém: aí é erro. */
trocar(
  'acompanhantes: validação',
  "    if (s.passo === 3 && !s.acomp) e.acomp = 'Selecione uma opção.';",
  `    if (s.passo === 3 && !s.acomp) e.acomp = 'Selecione uma opção.';
    if (s.passo === 3 && s.acomp && s.acomp !== ACOMP[0]) {
      if (!s.acompanhantes.some(p => p.nome.trim())) e.acompLista = 'Informe pelo menos um acompanhante.';
      const itens = s.acompanhantes.map(p => {
        if (!p.nome.trim()) return '';
        if (p.nome.trim().split(/\\s+/).length < 2) return 'Informe o nome completo, com sobrenome.';
        if (!p.parentesco) return 'Selecione o grau de parentesco.';
        if (p.email.trim() && !/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(p.email.trim())) return 'Email inválido.';
        return '';
      });
      // Só entra em \`e\` se houver erro: chave presente em \`e\`
      // trava o avancar(), mesmo com valor vazio.
      if (itens.some(Boolean)) e.acompItens = itens;
    }`
);

trocar(
  'acompanhantes: valores para a tela',
  "      acompOpts: this.radio('acomp', ACOMP),",
  `      acompOpts: ACOMP.map(label => ({
        label, on: s.acomp === label,
        pick: () => this.escolherAcomp(label)
      })),
      mostrarAcomp: !!s.acomp && s.acomp !== ACOMP[0],
      podeAdicionarAcomp: s.acompanhantes.length < 3,
      adicionarAcomp: this.adicionarAcomp,
      errAcompLista: e.acompLista || '',
      acompanhantes: s.acompanhantes.map((p, i) => ({
        titulo: 'Acompanhante ' + (i + 1),
        podeRemover: s.acompanhantes.length > 1,
        remover: this.removerAcomp(i),
        nome: p.nome,         setNome: this.editarAcomp(i, 'nome'),
        email: p.email,       setEmail: this.editarAcomp(i, 'email'),
        telefone: p.telefone, setTelefone: this.editarAcomp(i, 'telefone'),
        parentescoOpts: PARENTESCO.map(label => ({
          label, on: p.parentesco === label,
          pick: () => this.setState(st => ({
            acompanhantes: st.acompanhantes.map((q, j) =>
              j === i ? Object.assign({}, q, { parentesco: label }) : q)
          }))
        })),
        erro: (e.acompItens || [])[i] || ''
      })),`
);

/* A etapa 3 tinha um bloco só, a pergunta. Ganha um invólucro em
   coluna — com o mesmo respiro da etapa 5, que também empilha
   blocos — para a lista entrar como irmã da pergunta, e não
   grudada nela. */
trocar(
  'acompanhantes: invólucro da etapa 3',
  `<sc-if value="{{ s3 }}" hint-placeholder-val="{{ false }}">
<div style="display:flex;flex-direction:column;gap:14px">
<label`,
  `<sc-if value="{{ s3 }}" hint-placeholder-val="{{ false }}">
<div style="display:flex;flex-direction:column;gap:clamp(26px,3vw,38px)">
<div style="display:flex;flex-direction:column;gap:14px">
<label`
);

trocar(
  'acompanhantes: os campos na tela',
  `<sc-if value="{{ errAcomp }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errAcomp }}</span></sc-if>
</div>
</sc-if>`,
  `<sc-if value="{{ errAcomp }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errAcomp }}</span></sc-if>
</div>

<sc-if value="{{ mostrarAcomp }}" hint-placeholder-val="{{ false }}">
<div style="display:flex;flex-direction:column;gap:clamp(20px,2.5vw,28px)">

<p style="margin:0;padding:18px 20px;background:var(--color-accent-100);border-left:6px solid var(--color-accent);font:400 15px/1.6 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Cada acompanhante recebe o próprio crachá, necessário para entrar no evento. Informe quem vai junto — no máximo 3 pessoas, todas maiores de idade.</p>

<sc-for list="{{ acompanhantes }}" as="p" hint-placeholder-count="1">
<div style="display:flex;flex-direction:column;gap:16px;padding:clamp(18px,2.5vw,24px);border:2px solid var(--color-neutral-300);background:#fff">

<div style="display:flex;align-items:center;justify-content:space-between;gap:14px">
<span style="font:600 12px/1 var(--font-heading);letter-spacing:.14em;text-transform:uppercase;color:var(--brand-red)">{{ p.titulo }}</span>
<sc-if value="{{ p.podeRemover }}" hint-placeholder-val="{{ false }}"><button type="button" sc-camel-on-click="{{ p.remover }}" style="background:none;border:none;padding:4px;font:600 12px/1 var(--font-heading);letter-spacing:.08em;text-transform:uppercase;color:var(--color-neutral-600);cursor:pointer;text-decoration:underline">Remover</button></sc-if>
</div>

<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Nome completo <span style="color:var(--brand-red)">*</span></label>
<input class="inp" type="text" placeholder="Nome e sobrenome" value="{{ p.nome }}" sc-camel-on-change="{{ p.setNome }}">
</div>

<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Grau de parentesco <span style="color:var(--brand-red)">*</span></label>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px">
<sc-for list="{{ p.parentescoOpts }}" as="o" hint-placeholder-count="4">
<button class="opt" type="button" role="radio" aria-checked="{{ o.on }}" sc-camel-on-click="{{ o.pick }}" style="display:flex;align-items:center;gap:13px;padding:14px 15px;background:#fff;border:2px solid var(--color-neutral-300);color:var(--color-text);font:500 15px/1.3 var(--font-body);text-align:left;cursor:pointer">
<span class="mk" style="width:13px;height:13px;flex:none;border:2px solid var(--color-neutral-400)"></span>{{ o.label }}</button>
</sc-for>
</div>
</div>

<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px">
<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Email</label>
<input class="inp" type="email" placeholder="opcional" value="{{ p.email }}" sc-camel-on-change="{{ p.setEmail }}">
</div>
<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Telefone</label>
<input class="inp" type="tel" placeholder="opcional" value="{{ p.telefone }}" sc-camel-on-change="{{ p.setTelefone }}">
</div>
</div>

<sc-if value="{{ p.erro }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ p.erro }}</span></sc-if>
</div>
</sc-for>

<sc-if value="{{ podeAdicionarAcomp }}" hint-placeholder-val="{{ true }}">
<button type="button" sc-camel-on-click="{{ adicionarAcomp }}" style="align-self:flex-start;display:inline-flex;align-items:center;gap:10px;padding:14px 20px;background:#fff;border:2px solid var(--color-text);color:var(--color-text);font:600 13px/1 var(--font-heading);letter-spacing:.08em;text-transform:uppercase;cursor:pointer">+ Adicionar acompanhante</button>
</sc-if>

<sc-if value="{{ errAcompLista }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errAcompLista }}</span></sc-if>
</div>
</sc-if>
</div>
</sc-if>`
);

/* Linha no resumo da confirmação. */
trocar(
  'acompanhantes: linha no resumo',
  "      { q: 'Ciência e autorização', a: s.ciencia ? 'Sim, tenho ciência e autorizo' : '—' },",
  `      { q: 'Acompanhantes', a: s.acomp === ACOMP[0] || !s.acompanhantes.length ? '—'
          : s.acompanhantes.filter(p => p.nome.trim())
              .map(p => p.nome.trim() + (p.parentesco ? ' (' + p.parentesco + ')' : ''))
              .join(', ') || '—' },
      { q: 'Ciência e autorização', a: s.ciencia ? 'Sim, tenho ciência e autorizo' : '—' },`
);

/* ---- 26. texto novo das orientações ----

   A seção tinha três blocos: alunos das demais unidades, alunos
   da Unidade Américas, e participação dos responsáveis. Passa a
   ter dois: chegada/credenciamento e participação dos
   responsáveis.

   Ganha também a tarja de cima com o nome do evento e um título
   próprio — o antigo <h2> era a frase de abertura fazendo as
   vezes de título, e ela volta para o corpo, onde é uma frase.

   SAI INFORMAÇÃO OPERACIONAL: os horários de dispensa das aulas
   (08h10 para as demais unidades, 9h para a Américas) não estão
   no texto novo. Está anotado na resposta.

   Reconstrói a seção inteira em vez de trocar frase por frase
   porque a quantidade de blocos mudou. Os estilos são os mesmos
   de antes, copiados dos elementos originais. */
remover(
  'orientações: tira os três blocos antigos',
  '<h2 style="margin:0 0 8px;font:800 clamp(26px,3vw,40px)/1.06 var(--font-heading);letter-spacing:-0.03em;text-transform:uppercase">Para o dia do evento',
  'realizem sua inscrição através do mesmo formulário de interesse.</p>\n</div>\n</div>\n'
);

trocar(
  'orientações: texto novo',
  '<section id="orientacoes" class="rv" style="padding:clamp(48px,6vw,88px) clamp(20px,4vw,56px);border-bottom:2px solid var(--color-text)">\n',
  `<section id="orientacoes" class="rv" style="padding:clamp(48px,6vw,88px) clamp(20px,4vw,56px);border-bottom:2px solid var(--color-text)">
<div style="font:600 12px/1 var(--font-heading);letter-spacing:.18em;text-transform:uppercase;color:var(--brand-red);margin-bottom:16px">${NOME} · 3ª Edição</div>
<h2 style="margin:0 0 8px;font:800 clamp(26px,3vw,40px)/1.06 var(--font-heading);letter-spacing:-0.03em;text-transform:uppercase">Orientações logísticas para o dia do evento</h2>
<p style="margin:22px 0 0;max-width:72ch;font:400 16px/1.7 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Para o dia do evento, seguem as orientações logísticas importantes:</p>
<div style="width:56px;height:2px;background:var(--brand-red);margin:22px 0 44px"></div>
<div style="display:flex;flex-direction:column">
<div style="display:grid;grid-template-columns:minmax(0,330px) minmax(0,1fr);gap:clamp(16px,4vw,56px);padding:30px 0;border-top:2px solid var(--color-divider)">
<h3 style="margin:0;font:800 clamp(17px,1.7vw,21px)/1.24 var(--font-heading);letter-spacing:-0.01em">Chegada e credenciamento</h3>
<p style="margin:0;max-width:72ch;font:400 16px/1.7 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Os alunos inscritos deverão chegar à Unidade Américas com antecedência ao início da feira, às 9h, acompanhados de seus responsáveis, a fim de realizarem o credenciamento de acesso. O credenciamento estará disponível a partir das <strong style="font-weight:700">8h50, no 3º andar.</strong></p>
</div>
<div style="display:grid;grid-template-columns:minmax(0,330px) minmax(0,1fr);gap:clamp(16px,4vw,56px);padding:30px 0;border-top:2px solid var(--color-divider)">
<h3 style="margin:0;font:800 clamp(17px,1.7vw,21px)/1.24 var(--font-heading);letter-spacing:-0.01em">Participação dos responsáveis</h3>
<p style="margin:0;max-width:72ch;font:400 16px/1.7 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Reconhecemos a importância do envolvimento da família na jornada educacional de nossos alunos. Por isso, os responsáveis que desejarem acompanhar seus filhos no ${NOME} são muito bem-vindos! Contudo, para fins de controle de acesso e organização do evento, solicitamos gentilmente que também realizem sua inscrição por meio do mesmo formulário de interesse.</p>
</div>
</div>
`
);

/* ---- 27. texto novo da seção "O evento" ----

   Cinco parágrafos viram oito, e a seção ganha a mesma tarja das
   orientações, com o nome do evento e a edição.

   O último parágrafo continua com o realce de barra lateral que
   o antigo tinha: é o que traz o prazo, e prazo é a informação
   que a família precisa achar sem ler o resto.

   Duas coisas se acertaram com este texto:
   - "3ª Edição" agora bate com a seção de orientações. Antes a
     página dizia 1ª aqui e 3ª lá.
   - o público passa a incluir o 9º ano do Ensino Fundamental, que
     já estava na lista de anos do formulário mas não era citado
     no texto.

   Corrigido "antecipadamentecaso", que veio sem o espaço. */
remover(
  'evento: tira o texto antigo',
  '<div style="display:grid;grid-template-columns:minmax(0,260px) minmax(0,1fr);gap:clamp(24px,5vw,72px)">',
  'Solicitamos a atenção de todos para o prazo de inscrição, pois as vagas são limitadas.</p>\n</div>\n</div>\n'
);

trocar(
  'evento: texto novo',
  '<section id="evento" class="rv" style="padding:clamp(48px,7vw,100px) clamp(20px,4vw,56px);border-bottom:2px solid var(--color-text)">\n',
  `<section id="evento" class="rv" style="padding:clamp(48px,7vw,100px) clamp(20px,4vw,56px);border-bottom:2px solid var(--color-text)">
<div style="display:grid;grid-template-columns:minmax(0,260px) minmax(0,1fr);gap:clamp(24px,5vw,72px)">
<div>
<div style="font:600 12px/1.5 var(--font-heading);letter-spacing:.18em;text-transform:uppercase;color:var(--brand-red);margin-bottom:16px">${NOME} · 3ª Edição</div>
<h2 style="margin:0;font:800 clamp(28px,3.4vw,44px)/1 var(--font-heading);letter-spacing:-0.03em;text-transform:uppercase">O evento</h2>
<div style="width:56px;height:2px;background:var(--brand-red);margin-top:18px"></div>
</div>
<div style="display:flex;flex-direction:column;gap:26px;max-width:78ch">
<p style="margin:0;font:400 clamp(16px,1.4vw,18px)/1.72 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">A <strong style="font-weight:700">${CONTROLADOR}</strong>, em sua constante busca por excelência e inovação na formação de seus estudantes, tem a imensa satisfação de anunciar um evento de magnitude singular, concebido para inspirar e guiar nossos jovens talentos rumo a um futuro sem fronteiras.</p>
<p style="margin:0;font:400 clamp(16px,1.4vw,18px)/1.72 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Em um mundo cada vez mais interconectado, a visão de uma carreira internacional e a formação de líderes com uma mentalidade global tornam-se imperativos. É com esse compromisso inabalável que a ${CONTROLADOR} se dedica a acompanhar e incentivar cada um de nossos alunos a se tornarem cidadãos globais, aptos a explorar e conquistar oportunidades que se estendem muito além das fronteiras do Brasil.</p>
<p style="margin:0;font:400 clamp(16px,1.4vw,18px)/1.72 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Vimos, então, comunicar a realização da 3ª Edição do ${NOME}, um evento que representa uma ponte direta entre nossos alunos e as mais prestigiadas instituições de ensino superior do Brasil e do mundo. Esta será a maior feira de carreiras e universidades nacionais e internacionais já realizada pela Rede, um marco que reafirma o pioneirismo da ${CONTROLADOR} na formação de cidadãos globais.</p>
<p style="margin:0;font:400 clamp(16px,1.4vw,18px)/1.72 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Com um caráter verdadeiramente nacional e internacional, a feira reunirá em um mesmo espaço universidades nacionais e internacionais, proporcionando aos nossos alunos um panorama completo das possibilidades de formação dentro e fora do país. Trata-se de uma oportunidade verdadeiramente única e imperdível, cuidadosamente planejada para abrir portas e desmistificar o caminho para a educação global.</p>
<p style="margin:0;font:400 clamp(16px,1.4vw,18px)/1.72 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Este encontro transformador ocorrerá na Unidade Américas, no dia <strong style="font-weight:700">22 de agosto de 2026, das 9h às 12h.</strong></p>
<p style="margin:0;font:400 clamp(16px,1.4vw,18px)/1.72 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">A participação neste evento de alto nível é direcionada aos alunos do 9º ano do Ensino Fundamental e das 1ª, 2ª e 3ª Séries do Ensino Médio de todas as unidades da ${CONTROLADOR}. Acreditamos que esta experiência enriquecedora é fundamental para o planejamento acadêmico e profissional de nossos jovens, oferecendo uma perspectiva global que os preparará para os desafios e as oportunidades do século XXI.</p>
<p style="margin:0;font:400 clamp(16px,1.4vw,18px)/1.72 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">A inscrição prévia é necessária, uma vez que todos os participantes receberão uma credencial. Haverá credenciamento para a entrada no evento e para a participação junto aos representantes das universidades. <strong style="font-weight:700">Todos os presentes na feira precisam estar inscritos, inclusive os acompanhantes</strong>, para que seja gerada a respectiva credencial de acesso.</p>
<p style="margin:0;padding:22px 24px;background:#fff;border-left:6px solid var(--color-accent);font:500 clamp(16px,1.4vw,18px)/1.7 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Solicitamos a atenção de todos para o prazo de inscrição, pois as vagas são limitadas de acordo com a disponibilidade de espaço físico, podendo o formulário ser encerrado antecipadamente caso seja atingida a capacidade máxima do evento. <strong style="font-weight:700">As inscrições se encerram no dia 19/08/2026, às 23h59.</strong> A presença será confirmada exclusivamente mediante o preenchimento deste formulário de interesse.</p>
</div>
</div>
`
);

/* ---- 28. "Rede" fora das referências de endereço ----

   "Rede" identifica a instituição; endereço identifica um prédio.
   Nos dois pontos em que o nome aparece dizendo ONDE o evento
   acontece, ele volta a ser só "Alfacem Global Academy".

   São dois porque o rodapé faz a mesma coisa que o bloco LOCAL —
   diz o lugar — e deixar um com "Rede" e outro sem seria a mesma
   página se contradizendo.

   Roda depois da seção 24, que prefixa tudo. Prefixar e depois
   tirar de dois lugares é mais claro do que a 24 ter uma lista de
   exceções. */

trocar(
  'endereço: bloco LOCAL sem "Rede"',
  '>Rede Alfacem Global Academy · Américas<',
  '>Alfacem Global Academy · Américas<'
);

trocar(
  'endereço: rodapé sem "Rede"',
  '· Rede Alfacem Global Academy Américas ·',
  '· Alfacem Global Academy Américas ·'
);

/* ---- 29. College Counselor externo ----

   Terceira opção na etapa 1. Escolhida, o formulário deixa de ter
   cinco etapas e vira uma só: quatro campos, termo curto, enviar.
   Nada de aluno, responsável, acompanhante ou cascata de unidade.

   O caminho da família não é tocado — as validações e o envio
   dele continuam onde estavam. O counselor tem função própria no
   banco (inscrever_counselor, migration 0014) pelo mesmo motivo:
   dois fluxos numa função só viram `if` no meio de cada
   validação.

   ATENÇÃO ao ehAluno: ele era `alunoAlfa !== ALUNO_ALFA[1]`, o
   que com três opções passaria a ser verdadeiro para o counselor
   e abriria os campos de unidade/segmento/ano para ele. Vira
   comparação positiva com a opção do aluno da rede. */

/* Quatro perfis, e a pergunta deixou de ser sobre o aluno: quem
   preenche pode ser o responsável de um aluno, um counselor
   externo ou um docente da Rede.

   ehProf() dá nome à condição "veio sozinho, sem aluno". Ela
   aparece em sete lugares — rótulo da etapa, barra de progresso,
   botão, validação, envio, resumo e índice — e escrever
   `=== ALUNO_ALFA[2] || === ALUNO_ALFA[3]` em cada um deles é
   como um quarto perfil entra e três lugares ficam para trás. */
trocar(
  'perfis: counselor e docente na etapa 1',
  "const ALUNO_ALFA = ['Sim, estuda na Rede Alfacem Global Academy','Não, estuda em outro colégio'];",
  `const ALUNO_ALFA = [
  'Aluno da Rede Alfacem Global Academy',
  'Aluno de outro colégio',
  'College Counselor externo',
  'Docente da Rede Alfacem Global Academy'
];

/* Veio sozinho: sem aluno, sem responsável, sem acompanhante. */
function ehProf(v) { return v === ALUNO_ALFA[2] || v === ALUNO_ALFA[3]; }
function ehDocente(v) { return v === ALUNO_ALFA[3]; }`
);

trocar(
  'perfis: pergunta deixa de falar só de aluno',
  '>O aluno estuda na Rede Alfacem Global Academy? <',
  '>Quem está sendo inscrito? <'
);

trocar(
  'counselor: ehAluno vira comparação positiva',
  "ehAluno: s.alunoAlfa !== ALUNO_ALFA[1],",
  "ehAluno: s.alunoAlfa === ALUNO_ALFA[0],"
);

trocarTodas(
  'counselor: estado (state e reiniciar)',
  "ciencia: false, assinatura: '', acompanhantes: []",
  "ciencia: false, assinatura: '', acompanhantes: [], counNome: '', counEmail: '', counTel: '', counInst: ''"
);

/* Uma etapa só, e o rótulo e a barra de progresso acompanham. */
trocar(
  'counselor: uma etapa em vez de cinco',
  '      passoLabel:',
  `      ehProfissional: ehProf(s.alunoAlfa),
      ehCounselorExterno: s.alunoAlfa === ALUNO_ALFA[2],
      ehDocenteRede: ehDocente(s.alunoAlfa),
      ehResponsavel: !ehProf(s.alunoAlfa),
      unidadeProfOpts: this.radio('counInst', UNIDADES),
      counNome: s.counNome, setCounNome: this.set('counNome'),
      counEmail: s.counEmail, setCounEmail: this.set('counEmail'),
      counTel: s.counTel, setCounTel: this.set('counTel'),
      counInst: s.counInst, setCounInst: this.set('counInst'),
      errCounNome: e.counNome || '', errCounEmail: e.counEmail || '',
      errCounInst: e.counInst || '',
      passoLabel:`
);

trocar(
  'counselor: rótulo e progresso de uma etapa',
  "      passoLabel: 'Etapa ' + s.passo + ' de ' + total + ' · ' + TITULOS[s.passo - 1],\n      pct: Math.round((s.passo / total) * 100) + '%',\n      podeVoltar: s.passo > 1,",
  `      passoLabel: ehProf(s.alunoAlfa)
        ? 'Etapa 1 de 1 · ' + (ehDocente(s.alunoAlfa) ? 'Docente' : 'College Counselor')
        : 'Etapa ' + s.passo + ' de ' + total + ' · ' + TITULOS[s.passo - 1],
      pct: (ehProf(s.alunoAlfa) ? 100 : Math.round((s.passo / total) * 100)) + '%',
      podeVoltar: s.passo > 1 && !ehProf(s.alunoAlfa),`
);

trocar(
  'counselor: botão envia na primeira etapa',
  "botaoLabel: s.enviando ? 'Enviando…' : (s.passo === 5 ? 'Enviar inscrição' : 'Continuar'),",
  "botaoLabel: s.enviando ? 'Enviando…' : ((s.passo === 5 || ehProf(s.alunoAlfa)) ? 'Enviar inscrição' : 'Continuar'),"
);

/* A validação do counselor substitui a da etapa 1, não soma:
   ele não tem responsável nem parentesco para preencher. */
trocar(
  'counselor: validação própria da etapa 1',
  `    if (s.passo === 1) {
      if (!s.alunoAlfa) e.alunoAlfa = 'Selecione uma opção.';`,
  `    if (s.passo === 1 && ehProf(s.alunoAlfa)) {
      if (!s.counNome.trim()) e.counNome = 'Preencha o nome completo.';
      else if (s.counNome.trim().split(/\\s+/).length < 2) e.counNome = 'Informe o nome completo, com sobrenome.';
      if (!s.counEmail.trim()) e.counEmail = 'Preencha o email institucional.';
      else if (!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(s.counEmail.trim())) e.counEmail = 'Email inválido.';
      if (!s.counInst.trim()) e.counInst = ehDocente(s.alunoAlfa) ? 'Selecione a unidade onde atua.' : 'Informe a instituição.';
      if (!s.ciencia) e.ciencia = 'É necessário marcar que você tem ciência e autoriza.';
      return e;
    }
    if (s.passo === 1) {
      if (!s.alunoAlfa) e.alunoAlfa = 'Selecione uma opção.';`
);

/* avancar() na etapa 1 do counselor envia em vez de continuar. */
trocar(
  'counselor: avancar envia direto',
  `  avancar = () => {
    const e = this.erros();
    if (Object.keys(e).length) { this.setState({ tentou: true }); return; }`,
  `  avancar = () => {
    const e = this.erros();
    if (Object.keys(e).length) { this.setState({ tentou: true }); return; }
    if (ehProf(this.state.alunoAlfa)) { this.enviarCounselor(); return; }`
);

trocar(
  'counselor: método de envio',
  '  enviar = async () => {',
  `  enviarCounselor = async () => {
    if (this.state.enviando) return;
    this.setState({ enviando: true, erroEnvio: '' });

    const s = this.state;
    const ERROS = {
      nome_obrigatorio: 'Preencha o nome completo.',
      email_obrigatorio: 'Preencha o email institucional.',
      email_invalido: 'O email não parece válido.',
      instituicao_obrigatoria: 'Informe a instituição ou a unidade.',
      tipo_invalido: 'Perfil de inscrição inválido. Recarregue a página e tente de novo.',
      ciencia_obrigatoria: 'É necessário marcar a ciência e autorização.',
      inscricao_duplicada: 'Você já está inscrito com este e-mail. Se não recebeu a confirmação, procure na caixa de spam.',
      limite_de_inscricoes: 'Já existem inscrições demais com este email.',
      muitas_tentativas: 'Muitas inscrições foram enviadas deste local nos últimos minutos. Aguarde alguns minutos e toque em Enviar novamente.'
    };

    try {
      const r = await fetch('${SUPABASE_URL}/rest/v1/rpc/inscrever_counselor', {
        method: 'POST',
        headers: {
          'apikey': '${SUPABASE_ANON_KEY}',
          'Authorization': 'Bearer ${SUPABASE_ANON_KEY}',
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ p_dados: {
          // A RPC valida contra a mesma lista do banco: a tela
          // pode ser burlada, o tipo não.
          tipo: ehDocente(s.alunoAlfa) ? 'docente' : 'counselor',
          nome: s.counNome.trim(),
          email: s.counEmail.trim().toLowerCase(),
          telefone: s.counTel.trim(),
          instituicao: s.counInst.trim(),
          ciencia_compartilhamento: s.ciencia
        }})
      });

      if (!r.ok) {
        const corpo = await r.text();
        let msg = 'Não foi possível enviar. Tente novamente em alguns instantes.';
        for (const chave in ERROS) if (corpo.indexOf(chave) >= 0) msg = ERROS[chave];
        throw new Error(msg);
      }

      this.setState({ enviado: true, enviando: false });
      const el = document.getElementById('inscricao');
      if (el) window.scrollTo({ top: el.offsetTop - 80, behavior: 'smooth' });
    } catch (err) {
      const semRede = !navigator.onLine || /failed to fetch|networkerror|load failed/i.test(err.message || '');
      this.setState({
        enviando: false,
        erroEnvio: semRede
          ? 'Sem conexão. Verifique a internet e toque em Enviar novamente.'
          : (err.message || 'Não foi possível enviar.')
      });
    }
  };

  enviar = async () => {`
);

/* Os campos do responsável só aparecem para quem é responsável. */
trocar(
  'counselor: esconde os campos do responsável',
  '<div style="display:flex;flex-direction:column;gap:12px">\n<p style="margin:0 0 6px;font:400 15px/1.6 var(--font-body);color:var(--color-neutral-700)">Esta inscrição é preenchida pelo responsável.',
  '<sc-if value="{{ ehResponsavel }}" hint-placeholder-val="{{ true }}">\n<div style="display:flex;flex-direction:column;gap:12px">\n<p style="margin:0 0 6px;font:400 15px/1.6 var(--font-body);color:var(--color-neutral-700)">Esta inscrição é preenchida pelo responsável.'
);

/* Fecha o sc-if do responsável e abre o bloco do counselor,
   ambos dentro da etapa 1. */
trocar(
  'counselor: os campos na tela',
  '<sc-if value="{{ errParentesco }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errParentesco }}</span></sc-if>\n</div>',
  `<sc-if value="{{ errParentesco }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errParentesco }}</span></sc-if>
</div>
</sc-if>

<!-- ehProfissional, e não ehCounselor: este bloco vale para o
     counselor externo E para o docente da Rede, que é o que
     ehProf() significa. O nome ehCounselor nunca existiu nos
     valores — o sc-if lia undefined, dava falso, e os campos
     não apareciam para nenhum dos dois perfis. A pessoa via só
     a pergunta e o botão, e o envio falhava numa validação
     cujas mensagens estavam dentro deste bloco invisível. -->
<sc-if value="{{ ehProfissional }}" hint-placeholder-val="{{ false }}">
<div style="display:flex;flex-direction:column;gap:clamp(20px,2.5vw,26px)">

<sc-if value="{{ ehCounselorExterno }}" hint-placeholder-val="{{ false }}">
<p style="margin:0;padding:18px 20px;background:var(--color-accent-100);border-left:6px solid var(--color-accent);font:400 15px/1.6 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Inscrição de College Counselor: informe seus dados e envie. Não é preciso cadastrar aluno nem acompanhante. Você receberá um crachá com QR próprio, que os representantes das universidades poderão escanear para guardar seu contato.</p>
</sc-if>
<sc-if value="{{ ehDocenteRede }}" hint-placeholder-val="{{ false }}">
<p style="margin:0;padding:18px 20px;background:var(--color-accent-100);border-left:6px solid var(--color-accent);font:400 15px/1.6 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Inscrição de docente da Rede: informe seus dados e envie. Esta inscrição é sua — se você também acompanha um aluno, ele precisa da inscrição dele, feita pelo responsável. Você receberá um crachá com QR próprio.</p>
</sc-if>

<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Nome completo <span style="color:var(--brand-red)">*</span></label>
<input class="inp" type="text" placeholder="Nome e sobrenome" value="{{ counNome }}" sc-camel-on-change="{{ setCounNome }}">
<sc-if value="{{ errCounNome }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errCounNome }}</span></sc-if>
</div>

<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Email institucional <span style="color:var(--brand-red)">*</span></label>
<input class="inp" type="email" placeholder="nome@instituicao.edu.br" value="{{ counEmail }}" sc-camel-on-change="{{ setCounEmail }}">
<sc-if value="{{ errCounEmail }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errCounEmail }}</span></sc-if>
</div>

<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Telefone</label>
<input class="inp" type="tel" placeholder="(21) 90000-0000" value="{{ counTel }}" sc-camel-on-change="{{ setCounTel }}">
</div>

<sc-if value="{{ ehCounselorExterno }}" hint-placeholder-val="{{ false }}">
<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Instituição <span style="color:var(--brand-red)">*</span></label>
<input class="inp" type="text" placeholder="Nome da instituição de ensino" value="{{ counInst }}" sc-camel-on-change="{{ setCounInst }}">
</div>
</sc-if>

<sc-if value="{{ ehDocenteRede }}" hint-placeholder-val="{{ false }}">
<div style="display:flex;flex-direction:column;gap:10px">
<label style="font:600 13px/1.3 var(--font-heading);letter-spacing:.08em;text-transform:uppercase">Unidade onde atua <span style="color:var(--brand-red)">*</span></label>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px">
<sc-for list="{{ unidadeProfOpts }}" as="o" hint-placeholder-count="8">
<button class="opt" type="button" role="radio" aria-checked="{{ o.on }}" sc-camel-on-click="{{ o.pick }}" style="display:flex;align-items:center;gap:13px;padding:14px 15px;background:#fff;border:2px solid var(--color-neutral-300);color:var(--color-text);font:500 15px/1.3 var(--font-body);text-align:left;cursor:pointer">
<span class="mk" style="width:13px;height:13px;flex:none;border:2px solid var(--color-neutral-400)"></span>{{ o.label }}</button>
</sc-for>
</div>
</div>
</sc-if>

<sc-if value="{{ errCounInst }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errCounInst }}</span></sc-if>

<div style="display:flex;flex-direction:column;gap:16px;padding:clamp(18px,2.5vw,24px);border:2px solid var(--color-text);background:#fff">
<div style="display:flex;flex-direction:column;gap:8px">
<div style="font:600 11px/1.5 var(--font-heading);letter-spacing:.16em;text-transform:uppercase;color:var(--brand-red)">Career Day · Alfa University Fair</div>
<div style="font:800 clamp(17px,1.9vw,20px)/1.2 var(--font-heading);letter-spacing:-0.01em;color:var(--color-text)">Termo de Ciência e Autorização</div>
<div style="font:400 14px/1.5 var(--font-body);color:var(--color-neutral-700)">Compartilhamento dos seus dados profissionais com as instituições participantes.</div>
</div>
<p style="margin:0;font:400 15px/1.66 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Declaro que os dados aqui informados são meus, verdadeiros e exatos, e que os presto por mim mesmo, na qualidade de profissional maior de idade.</p>
<p style="margin:0;font:400 15px/1.66 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Tenho ciência de que serão coletados e tratados pela ${CONTROLADOR}, na condição de controladora, e compartilhados com as universidades e instituições de ensino participantes do ${NOME}, observada a Lei nº 13.709/2018 (Lei Geral de Proteção de Dados Pessoais – LGPD), com a seguinte finalidade: organizar o evento, emitir meu crachá de acesso e permitir que as instituições participantes entrem em contato comigo sobre programas, processos de aplicação e oportunidades de estudo.</p>
<p style="margin:0;font:400 15px/1.66 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty">Manifesto meu consentimento livre, informado e inequívoco para esse tratamento, ciente de que posso revogá-lo a qualquer momento e solicitar a exclusão dos meus dados pelo e-mail ${CONTATO_DADOS}.</p>
</div>

<div style="display:flex;flex-direction:column;gap:14px">
<button class="opt" type="button" role="checkbox" aria-checked="{{ cienciaOn }}" sc-camel-on-click="{{ cienciaPick }}" style="display:flex;align-items:flex-start;gap:13px;padding:18px 18px;background:#fff;border:2px solid var(--color-neutral-300);color:var(--color-text);font:500 16px/1.35 var(--font-body);text-align:left;cursor:pointer">
<span class="mk" style="width:13px;height:13px;flex:none;margin-top:4px;border:2px solid var(--color-neutral-400)"></span>Sim, tenho ciência e autorizo o compartilhamento dos meus dados nos termos acima.</button>
<sc-if value="{{ errCiencia }}" hint-placeholder-val="{{ false }}"><span style="font:500 13px/1.4 var(--font-body);color:var(--brand-red)">{{ errCiencia }}</span></sc-if>
</div>

<sc-if value="{{ erroEnvio }}" hint-placeholder-val="{{ false }}"><p style="margin:0;padding:16px 18px;border:2px solid var(--brand-red);background:#fff;font:500 15px/1.5 var(--font-body);color:var(--brand-red)">{{ erroEnvio }}</p></sc-if>
</div>
</sc-if>`
);

/* ---- 30. o que acontece depois de enviar ----

   A tela dizia "Inscrição registrada. Confira abaixo o resumo" e
   parava aí. Quem preenche fica sem saber se falta fazer algo,
   se vale imprimir a página, ou como entra no evento — e as
   dúvidas viram ligação para a secretaria.

   Três coisas passam a estar escritas: chega e-mail de
   confirmação, o crachá é entregue no dia, e o QR do crachá é o
   que o representante escaneia.

   A caixa de spam é citada de propósito: e-mail automático de
   domínio novo cai em spam com frequência, e o pai que não
   encontrar vai supor que a inscrição falhou. */
trocar(
  'confirmação: explica o que vem depois',
  '<p style="margin:0;max-width:52ch;font:400 16px/1.7 var(--font-body);color:var(--color-neutral-800)">Confira abaixo o resumo das suas respostas.</p>',
  `<p style="margin:0;max-width:52ch;font:400 16px/1.7 var(--font-body);color:var(--color-neutral-800)">Confira abaixo o resumo das suas respostas.</p>
<div style="display:flex;flex-direction:column;gap:20px;margin:6px 0 10px;padding:24px 26px;background:var(--color-accent-100);border-left:6px solid var(--color-accent);max-width:62ch">
<div style="font:600 12px/1 var(--font-heading);letter-spacing:.14em;text-transform:uppercase;color:var(--brand-red)">Próximos passos</div>

<div style="display:flex;align-items:flex-start;gap:14px">
<span style="width:26px;height:26px;flex:none;display:flex;align-items:center;justify-content:center;background:var(--color-accent);color:#fff;font:800 12px/1 var(--font-heading)">1</span>
<p style="margin:0;font:400 15px/1.6 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty"><strong style="font-weight:700">Em até 10 minutos</strong> você vai receber um e-mail de confirmação no endereço que informou, com os detalhes do evento e o número de protocolo desta inscrição. Não chegou? Verifique a caixa de spam ou lixo eletrônico.</p>
</div>

<div style="display:flex;align-items:flex-start;gap:14px">
<span style="width:26px;height:26px;flex:none;display:flex;align-items:center;justify-content:center;background:var(--color-accent);color:#fff;font:800 12px/1 var(--font-heading)">2</span>
<p style="margin:0;font:400 15px/1.6 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty"><strong style="font-weight:700">No dia do evento</strong>, apresente-se no credenciamento a partir das 8h50, no 3º andar, para retirar o crachá. Não é preciso imprimir nada.</p>
</div>

<div style="display:flex;align-items:flex-start;gap:14px">
<span style="width:26px;height:26px;flex:none;display:flex;align-items:center;justify-content:center;background:var(--color-accent);color:#fff;font:800 12px/1 var(--font-heading)">3</span>
<p style="margin:0;font:400 15px/1.6 var(--font-body);color:var(--color-neutral-900);text-wrap:pretty"><strong style="font-weight:700">Durante a feira</strong>, o crachá traz um QR code — é por ele que os representantes das universidades registram o contato. Basta apresentá-lo ao conversar com cada instituição.</p>
</div>
</div>`
);

/* ---- 31. resumo adaptado ao tipo de inscrição ----

   O resumo listava as 19 linhas sempre, e o counselor via 12
   delas preenchidas com travessão: unidade, segmento, ano, países
   de interesse, acompanhantes, assinatura. Nenhuma dessas
   perguntas foi feita a ele.

   Travessão significa "perguntamos e você não respondeu". Para
   pergunta que nunca existiu, a linha não deve aparecer.

   O counselor tem resumo próprio, com os quatro campos que
   preencheu mais a ciência. O da família fica exatamente como
   estava. */
trocar(
  'resumo: linhas conforme o tipo de inscrição',
  '    const resumo = [\n      { q: \'Aluno da Rede Alfacem Global Academy?\', a: s.alunoAlfa },',
  `    const resumo = ehProf(s.alunoAlfa) ? [
      { q: 'Tipo de inscrição', a: s.alunoAlfa },
      { q: 'Nome completo', a: s.counNome },
      { q: 'Email institucional', a: s.counEmail },
      { q: 'Telefone', a: s.counTel || '—' },
      { q: ehDocente(s.alunoAlfa) ? 'Unidade' : 'Instituição', a: s.counInst },
      { q: 'Ciência e autorização', a: s.ciencia ? 'Sim, tenho ciência e autorizo' : '—' }
    ] : [
      { q: 'Aluno da Rede Alfacem Global Academy?', a: s.alunoAlfa },`
);

/* ---- 32. lista de etapas adaptada ----

   O índice lateral mostrava as cinco etapas da família mesmo
   quando o counselor estava na tela: "Dados do aluno",
   "Acompanhante", "Interesses do aluno", "Autorizações" — quatro
   etapas que ele nunca vai percorrer, listadas em cinza como se
   estivessem por vir.

   Vira uma linha só. O map continua o mesmo; muda só a lista que
   ele percorre. */
trocar(
  'etapas: uma só para o counselor',
  '      etapas: TITULOS.map((t, i) => ({',
  `      etapas: (ehProf(s.alunoAlfa) ? [ehDocente(s.alunoAlfa) ? 'Docente' : 'College Counselor'] : TITULOS).map((t, i) => ({`
);

/* ---- reempacota ----

   JSON.stringify não escapa `<`, então um `</script>` dentro do
   template sairia literal e fecharia a tag que o envolve — o
   navegador pararia de ler o arquivo ali. O bundler original
   escapa; nós precisamos escapar também.

   < é JSON válido e some na hora do JSON.parse, então o
   template chega íntegro ao carregador. */
const json = JSON.stringify(tpl).replace(/</g, '\\u003c');

if (json.includes('</')) {
  console.error('Escape falhou: ainda há "</" solto no JSON reempacotado.');
  process.exit(1);
}

let saida = bundle.replace(marcador, (_, abre, __, fecha) => abre + json + fecha);

/* O <title> fica no invólucro que o bundler gera, fora do template,
   e vem como "Bundled Page" — é o que a família vê na aba e no
   favorito. Fica aqui, e não em trocar(), porque trocar() opera
   sobre o template. */
const TITULO_ANTIGO = '<title>Bundled Page</title>';
const TITULO_NOVO   = `<title>${NOME} · alfacem global academy</title>`;

if (saida.includes(TITULO_ANTIGO)) {
  saida = saida.replace(TITULO_ANTIGO, TITULO_NOVO);
  alteracoes.push('<title> da aba');
} else if (!saida.includes(TITULO_NOVO)) {
  console.error('FALHOU: <title> do invólucro não encontrado. O bundler mudou?');
  process.exit(1);
}

/* ============================================================
   Prazo do aluno da Rede (migration 0034)

   Entra como script solto no fim da página, e não como troca
   dentro do template, por um motivo prático: o formulário é um
   componente que se redesenha inteiro a cada tecla, e qualquer
   `aria-disabled` que dependesse do estado dele exigiria mexer em
   três lugares do bundle. Aqui é DOM puro, do lado de fora, e o
   MutationObserver reaplica depois de cada redesenho.

   A hora vem do SERVIDOR, não do aparelho. Celular com data
   adiantada bloquearia uma família antes do prazo; com data
   atrasada deixaria preencher cinco etapas para nada.

   Enquanto a chamada não responde, a opção continua clicável — na
   dúvida, a favor de quem está preenchendo. E o bloqueio é só da
   tela: quem for inscrito no balcão ou pelo QR do cartaz no dia
   do evento passa por outra porta, que não tem prazo.
   ============================================================ */
const GUARDA_PRAZO = `
<script>
(function () {
  var ROTULO = 'aluno da rede';

  function achar() {
    var alvos = [];
    var botoes = document.querySelectorAll('button');
    for (var i = 0; i < botoes.length; i++) {
      var t = (botoes[i].textContent || '').toLowerCase();
      if (t.indexOf(ROTULO) === 0) alvos.push(botoes[i]);
    }
    return alvos;
  }

  function aplicar() {
    var alvos = achar();
    for (var i = 0; i < alvos.length; i++) {
      var b = alvos[i];
      if (b.dataset.prazoFechado) continue;
      b.dataset.prazoFechado = '1';
      /* Só a aparência de desligado, sem texto explicativo: a
         opção cinza já diz que não está disponível, e o cabeçalho
         do formulário continua trazendo a data do prazo. */
      b.setAttribute('aria-disabled', 'true');
      b.style.opacity = '.45';
      b.style.cursor = 'not-allowed';
    }
  }

  /* Captura: o clique é interrompido antes de chegar ao
     componente. Sem isto o estilo seria só enfeite — bastaria o
     toque, ou o teclado, para marcar a opção. */
  function barrar(ev) {
    var b = ev.target && ev.target.closest ? ev.target.closest('button') : null;
    if (b && b.dataset && b.dataset.prazoFechado) {
      ev.stopPropagation();
      ev.preventDefault();
    }
  }

  fetch('${SUPABASE_URL}/rest/v1/rpc/prazo_inscricao_rede', {
    method: 'POST',
    headers: {
      'apikey': '${SUPABASE_ANON_KEY}',
      'Authorization': 'Bearer ${SUPABASE_ANON_KEY}',
      'Content-Type': 'application/json'
    },
    body: '{}'
  })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (d) {
      if (!d || !d.encerrado) return;
      document.addEventListener('click', barrar, true);
      document.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') barrar(ev);
      }, true);
      aplicar();
      new MutationObserver(aplicar).observe(document.body,
        { childList: true, subtree: true });
    })
    .catch(function () { /* sem resposta: a opção segue aberta */ });
})();
<\/script>
`;

if (saida.includes('</body>')) {
  saida = saida.replace('</body>', GUARDA_PRAZO + '</body>');
  alteracoes.push('prazo do aluno da Rede: bloqueio na tela');
} else {
  console.error('FALHOU: não achei </body> para injetar a guarda de prazo.');
  process.exit(1);
}

writeFileSync(DESTINO, saida, 'utf8');

console.log('Alterações aplicadas:');
for (const a of alteracoes) console.log('  - ' + a);
console.log(`\n${DESTINO}  (${(saida.length / 1024).toFixed(0)} KB)`);
console.log('O bundle original não foi modificado.');
