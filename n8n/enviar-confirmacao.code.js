/* ============================================================
   Monta um e-mail por inscrição pendente.

   Cole este arquivo inteiro no nó Code chamado "Montar e-mail",
   em modo "Run Once for All Items".

   Aceita a fila em qualquer das três formas que o n8n pode
   entregar, conforme a versão e a configuração do nó HTTP:
     - um item por elemento (o nó dividiu o array)
     - um item único cujo json É o array
     - um item único com o array dentro de .data
   Sem isso o workflow quebra em silêncio quando a versão do n8n
   muda de comportamento.
   ============================================================ */

/* ---- CONFIGURE ISTO ----

   Endereço público da logo. Cliente de e-mail NÃO aceita imagem
   embutida em base64 — Gmail e Outlook descartam —, então ela
   precisa estar numa URL acessível pela internet.

   O arquivo logo-email.png vai junto para a pasta publicar/, e
   arquivo estático mantém o caminho exato no Cloudflare — o
   /inscricao sem extensão é roteamento só de HTML.

   Deixe vazio ('') para voltar ao cabeçalho escrito. É o estado
   seguro: melhor sem logo do que com o ícone de imagem quebrada
   num e-mail da escola.

   ATENÇÃO: se o site mudar de endereço, esta URL para de
   funcionar e todo e-mail novo sai com imagem quebrada. */
const LOGO_URL = 'https://fair.alfacem-global-academy.workers.dev/logo-email.png';

const EVENTO  = 'Career Day – Alfa University Fair';
const QUANDO  = '22 de agosto de 2026, das 9h às 12h';
const ONDE    = 'Alfacem Global Academy · Américas — Av. das Américas, 6551, Barra da Tijuca, Rio de Janeiro';
const CHEGADA = 'O credenciamento abre às 8h50, no 3º andar.';

/* ---- fim da configuração ---- */

const linhas = [];
for (const item of $input.all()) {
  const j = item.json;
  if (Array.isArray(j)) linhas.push(...j);
  else if (j && Array.isArray(j.data)) linhas.push(...j.data);
  else if (j && j.id) linhas.push(j);
}

const esc = (t) => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/* Com imagem, o alt garante o nome quando o cliente bloqueia
   remota — o que o Outlook faz por padrão. Sem imagem, o nome
   aparece escrito, no azul da marca. */
const cabecalho = LOGO_URL
  ? '<img src="' + LOGO_URL + '" alt="Rede Alfacem Global Academy" width="200" style="width:200px;max-width:60%;height:auto;display:block;margin:0 0 22px;border:0">'
  : '<p style="margin:0 0 22px;font-size:19px;font-weight:700;color:#1478d0;letter-spacing:-.01em">Rede Alfacem Global Academy</p>';

return linhas.map((d) => {
  const counselor = d.tipo === 'counselor';
  const docente   = d.tipo === 'docente';

  /* Série e unidade entre parênteses: são o que deixa o
     responsável conferir num relance que inscreveu o filho certo,
     na unidade certa. A fila já devolvia os dois — o texto é que
     usava só a série. Se algum vier vazio, o parêntese encolhe em
     vez de mostrar separador solto. */
  const contexto = [d.ano, d.instituicao].filter(Boolean).map(esc).join(' · ');

  const quem = docente
    ? '<p style="margin:0 0 16px">Sua inscrição como <strong>docente</strong> da unidade <strong>' + esc(d.instituicao) + '</strong> foi recebida.</p>'
    : counselor
    ? '<p style="margin:0 0 16px">Sua inscrição como <strong>College Counselor</strong> pela instituição <strong>' + esc(d.instituicao) + '</strong> foi recebida.</p>'
    : '<p style="margin:0 0 16px">A inscrição de <strong>' + esc(d.aluno) + '</strong>' + (contexto ? ' (' + contexto + ')' : '') + ' foi recebida.</p>';

  const acomp = (d.acompanhantes && d.acompanhantes.length)
    ? '<p style="margin:0 0 16px">Acompanhantes inscritos: <strong>' + esc(d.acompanhantes.join(', ')) + '</strong>. Cada um receberá o próprio crachá.</p>'
    : '';

  /* <table> nos blocos destacados, e não <div>: o Outlook ignora
     background e border em div, e o aviso sairia sem a tarja. */
  const html = '<div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:560px;margin:0 auto;padding:28px 24px;color:#201e1d;line-height:1.6;font-size:16px">'
    + cabecalho
    + '<p style="margin:0 0 4px;font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:#b02020">' + EVENTO + ' · 3ª Edição</p>'
    + '<h1 style="margin:0 0 20px;font-size:23px;line-height:1.25">Inscrição confirmada</h1>'

    + '<p style="margin:0 0 16px">Olá, ' + esc(d.destinatario) + '.</p>'
    + quem + acomp

    + '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 24px;background:#fff2ef;border-left:5px solid #ec3013">'
    +   '<tr><td style="padding:16px 18px">'
    +     '<p style="margin:0 0 10px"><strong>Quando:</strong> ' + QUANDO + '</p>'
    +     '<p style="margin:0 0 10px"><strong>Onde:</strong> ' + ONDE + '</p>'
    +     '<p style="margin:0"><strong>Chegada:</strong> ' + CHEGADA + '</p>'
    +   '</td></tr>'
    + '</table>'

    + '<h2 style="margin:0 0 8px;font-size:17px">Seu crachá</h2>'
    + '<p style="margin:0 0 16px">O crachá é entregue <strong>no dia do evento</strong>, no credenciamento. Não é preciso imprimir nada.</p>'
    + '<p style="margin:0 0 24px">Cada crachá traz um <strong>QR code</strong>. É por ele que os representantes das universidades registram o contato durante a feira — basta apresentá-lo ao conversar com cada instituição.</p>'

    + '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-top:1px solid #d7d3d3">'
    +   '<tr><td style="padding:16px 0 0">'
    +     '<p style="margin:0 0 6px;font-size:14px;color:#605d5d">Protocolo desta inscrição: <strong style="color:#201e1d">' + esc(d.protocolo) + '</strong></p>'
    +     '<p style="margin:0;font-size:14px;color:#605d5d">Guarde este e-mail. Se precisar corrigir alguma informação, responda a esta mensagem citando o protocolo.</p>'
    +   '</td></tr>'
    + '</table>'
    + '</div>';

  return {
    json: {
      id: d.id,
      destino: d.destino,
      assunto: 'Inscrição confirmada — ' + EVENTO,
      html: html
    }
  };
});
