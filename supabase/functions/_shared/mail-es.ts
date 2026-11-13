// Spanish for the buyer mails that SQL builds in English (mig 20261114130000,
// docs/i18n-review.md). Used by exos-mail-drain for rows whose lang is 'es'.
//
// About twenty SQL functions queue buyer mail (fulfilment, the door, transfers,
// comps) with an English subject and body. Rather than patch each of them
// (several sit on the checkout / mint path other branches patch too), the
// drain translates the fixed sentences of the mails it knows here, at send
// time. The row in exos_mail stays English, so the SQL that dedupes on a
// subject keeps working.
//
// All or nothing: localizeMailEs returns null, and the English row is sent,
// unless the subject matched one of the known shapes AND no English is left
// in the body outside the data (event and person names in <strong>, the
// receipt's line table, links' URLs). A mail is never half Spanish.
//
// Money and legal sentences (the refund, the all-in price line, the receipt)
// are marked REVIEW: a human checks them before launch (docs/i18n-review.md).
// Pure: Deno and EXP's vitest (src/lib/mailEs.test.ts) both load it.

type Rule = [RegExp, string | ((...m: string[]) => string)];

const tickets = (n: string) => (n === "1" ? "tu entrada" : `tus ${n} entradas`);

// Subjects carry the raw event name, so each is anchored on both ends.
const SUBJECTS: Rule[] = [
  [/^Your ticket for (.+) is ready$/s, "Tu entrada para $1 está lista"],
  [/^Your tickets for (.+) are ready$/s, "Tus entradas para $1 están listas"],
  [/^Your order for (.+) didn't go through$/s, "Tu pedido para $1 no se completó"],
  [/^You've been sent a ticket for (.+)$/s, "Te enviaron una entrada para $1"],
  [/^Your ticket for (.+) was accepted$/s, "Tu entrada para $1 fue aceptada"],
  [/^You sent your ticket for (.+) to (.+)$/s, "Enviaste tu entrada para $1 a $2"],
  [/^Your ticket for (.+)$/s, "Tu entrada para $1"],
  [/^Your tickets for (.+)$/s, "Tus entradas para $1"],
  [/^Someone sent you a ticket$/, "Alguien te envió una entrada"],
  [/^Your ticket transfer was claimed$/, "Alguien reclamó la entrada que transferiste"],
];

// Body sentences, most specific first. Event names sit between <strong> tags,
// which no rule crosses.
const BODY: Rule[] = [
  // ── order confirmation (exos_fulfill_checkout, _exos_proof_release, the door) ──
  [/Payment received — your (\d+) tickets? for <strong>/g, (_m, n) => `Pago recibido: ${tickets(n)} para <strong>`],
  [/Email confirmed\. Your (\d+) tickets? for <strong>/g, (_m, n) => `Correo confirmado. ${cap(tickets(n))} para <strong>`],
  [/(Payment received\.|You're in\.) Your (\d+) tickets? for <strong>/g,
    (_m, lead, n) => `${lead === "You're in." ? "¡Ya estás dentro!" : "Pago recibido."} ${cap(tickets(n))} para <strong>`],
  [/<p>Your ticket \(([^<]*?)\) for <strong>/g, "<p>Tu entrada ($1) para <strong>"],
  [/<p>Your ticket for <strong>/g, "<p>Tu entrada para <strong>"],
  [/<p>Your tickets for <strong>/g, "<p>Tus entradas para <strong>"],
  [/<\/strong> is in your Exos wallet\. /g, "</strong> ya está en tu billetera de Exos. "],
  [/<\/strong> are in your Exos wallet\. /g, "</strong> ya están en tu billetera de Exos. "],
  [/<\/strong> is in your wallet\. /g, "</strong> ya está en tu billetera. "],
  [/<\/strong> are in your wallet\. /g, "</strong> ya están en tu billetera. "],
  [/<\/strong> is waiting for you\. /g, "</strong> te espera. "],
  [/<\/strong> are waiting for you\. /g, "</strong> te esperan. "],
  [/<\/strong> are ready\. /g, "</strong> están listas. "],
  [/Open the app to show your QR at the door\./g, "Abre la app para mostrar tu código QR en la puerta."],
  [/Sign in to Exos with this email to show your QR at the door\./g,
    "Inicia sesión en Exos con este correo para mostrar tu código QR en la puerta."],
  [/Open a link below and sign in with a one-time code sent to this email \(no password needed\) to get your entry QR code\. /g,
    "Abre un enlace de abajo e inicia sesión con un código de un solo uso enviado a este correo (sin contraseña) para obtener tu código QR de entrada. "],
  [/Open a link below and sign in \(a one-time code, no password\) to get your entry QR code\. /g,
    "Abre un enlace de abajo e inicia sesión (un código de un solo uso, sin contraseña) para obtener tu código QR de entrada. "],
  [/Send a link to a friend and they can claim that ticket themselves\./g,
    "Envía un enlace a un amigo y podrá reclamar esa entrada por su cuenta."],
  [/>Claim ticket (\d+)<\/a>/g, ">Reclamar entrada $1</a>"],
  [/>Claim ticket<\/a>/g, ">Reclamar entrada</a>"],
  [/>Claim your ticket<\/a> and sign in with any Exos account, or create one\./g,
    ">Reclama tu entrada</a> e inicia sesión con cualquier cuenta de Exos, o crea una."],
  [/<p>Thanks for buying at the door\. Your tickets? for <strong>/g, "<p>Gracias por comprar en la puerta. Tu compra para <strong>"],
  [/<\/strong> (is|are) in the Exos app\. Show the QR at the door\./g, "</strong> ya está en la app de Exos. Muestra el código QR en la puerta."],
  [/<p>Thanks for buying at the door of <strong>/g, "<p>Gracias por comprar en la puerta de <strong>"],
  [/<\/strong>\. Sign in to Exos with this email, or create an account, to keep your tickets? in the app\./g,
    "</strong>. Inicia sesión en Exos con este correo, o crea una cuenta, para guardar tu compra en la app."],
  [/<p>You've been issued a ticket for <strong>/g, "<p>Te emitieron una entrada para <strong>"],
  [/<p>The organizer of <strong>/g, "<p>El organizador de <strong>"],
  [/<\/strong> sent you (\d+) tickets?\. Sign in to Exos with any Exos account, or create one, to claim (it|them)\./g,
    (_m, n) => `</strong> te envió ${n === "1" ? "1 entrada" : `${n} entradas`}. Inicia sesión en Exos con cualquier cuenta, o crea una, para reclamar${n === "1" ? "la" : "las"}.`],
  [/<\/strong>\. Open the app/g, "</strong>. Abre la app"],

  // ── the receipt (exos_receipt_html) · REVIEW: money ──
  [/<p>Paid: <strong>/g, "<p>Pagado: <strong>"],
  [/ \(including ([0-9.,]+) tax\)/g, " (incluye $1 de impuestos)"],
  [/\. Order reference: /g, ". Referencia del pedido: "],
  [/<p>Seats: /g, "<p>Asientos: "],
  [/<p>Seat: /g, "<p>Asiento: "],
  [/All-in price: the prices above include /g, "Precio final: los precios de arriba incluyen "],
  [/ and tax; nothing was added at checkout\./g, " e impuestos; no se agregó nada al pagar."],
  [/; nothing was added at checkout\./g, "; no se agregó nada al pagar."],
  [/All-in price: no fees were added at checkout and tax is included\./g,
    "Precio final: no se agregaron cargos al pagar y los impuestos están incluidos."],
  [/All-in price: no fees were added at checkout\./g, "Precio final: no se agregaron cargos al pagar."],
  [/>View your tickets<\/a>/g, ">Ver tus entradas</a>"],

  // ── order failed (exos_fulfill_checkout) · REVIEW: refund ──
  [/<p>Sorry, the tickets you picked for <strong>/g, "<p>Lo sentimos: las entradas que elegiste para <strong>"],
  [/<\/strong> sold out while you were paying, so your order didn't go through\. /g,
    "</strong> se agotaron mientras pagabas, así que tu pedido no se completó. "],
  [/<\/strong> couldn't be issued because you already have as many tickets as this event allows per person, so this order didn't go through\. /g,
    "</strong> no se pudieron emitir porque ya tienes el máximo de entradas por persona de este evento, así que este pedido no se completó. "],
  [/<\/strong> are on a members-only presale and your membership wasn't active when your payment came through, so your order didn't go through\. /g,
    "</strong> son de una preventa solo para miembros y tu membresía no estaba activa cuando llegó tu pago, así que tu pedido no se completó. "],
  [/<\/strong> couldn't be issued because the access code you used is no longer valid, so your order didn't go through\. /g,
    "</strong> no se pudieron emitir porque el código de acceso que usaste ya no es válido, así que tu pedido no se completó. "],
  [/<\/strong> couldn't be issued: your group's time ran out, or the host covered your seat, before your payment came through, so your order didn't go through\. /g,
    "</strong> no se pudieron emitir: se acabó el tiempo de tu grupo, o el anfitrión pagó tu lugar, antes de que llegara tu pago, así que tu pedido no se completó. "],
  [/Your payment is being refunded in full; it can take 5 to 10 days to show up\./g,
    "Te estamos reembolsando el pago completo; puede tardar de 5 a 10 días en aparecer."],

  // ── transfers (exos_queue_mail, exos_claim_transfer) ──
  [/<p>Someone sent you a ticket on Exos\.<\/p>/g, "<p>Alguien te envió una entrada en Exos.</p>"],
  [/<p>Whoever claims the link first gets the ticket, so keep this email to yourself\.<\/p>/g,
    "<p>Quien reclame el enlace primero se queda con la entrada, así que no compartas este correo.</p>"],
  [/<p>Good news — someone claimed the ticket you transferred\. The transfer is complete and the new owner's ticket is now active\.<\/p>/g,
    "<p>Buenas noticias: alguien reclamó la entrada que transferiste. La transferencia está completa y la entrada del nuevo titular ya está activa.</p>"],
];

function cap(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function apply(rules: Rule[], s: string): string {
  let out = s;
  // deno-lint-ignore no-explicit-any
  for (const [re, to] of rules) out = out.replace(re, to as any);
  return out;
}

// English left over once the data is taken out: any of these words means a
// sentence this file doesn't know, so the whole mail goes in English.
const ENGLISH = /\b(the|your|you|you're|you've|ticket|tickets|for|and|is|are|was|open|sign|this|with|order|payment|here|have|been|it|to|of|on|at|by|in|from|please|thanks)\b/i;

/** The text a reader sees, minus the data: names, the receipt table, URLs. */
export function leftoverText(html: string): string {
  return html
    .replace(/<strong>[\s\S]*?<\/strong>/g, " ")
    .replace(/<table[\s\S]*?<\/table>/g, " ")
    .replace(/<[^>]*>/g, " ")
    .replace(/https?:\/\/\S+|\{\{app_url\}\}\S*/g, " ")
    .replace(/&[a-z]+;|&#\d+;/g, " ");
}

/** The Spanish mail, or null to send the English row as it is. */
export function localizeMailEs(subject: string, html: string): { subject: string; html: string } | null {
  let s: string | null = null;
  for (const [re, to] of SUBJECTS) {
    if (re.test(subject)) {
      // deno-lint-ignore no-explicit-any
      s = subject.replace(re, to as any);
      break;
    }
  }
  if (s === null) return null;
  const h = apply(BODY, html);
  if (ENGLISH.test(leftoverText(h))) return null;
  return { subject: s, html: h };
}
