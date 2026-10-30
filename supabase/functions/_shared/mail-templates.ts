// Payload-rendered Exos mail (mig 20260929071000), used by exos-mail-drain.
//
// Rows queued by exos_mail_enqueue carry a JSON payload and an empty html;
// the drain calls renderTemplate() to build the subject and body. Pure (its
// one import, channelReport.ts, is pure too), so Deno and EXP's vitest
// (src/lib/mailTemplates.test.ts) both load it.

import {
  type ChannelRow, type EventChannels, feeText, messageRows, money, notReportedNote, parseChannelReport, plural, sideCounts,
  sumTickets, totalsText, weekLabel,
} from "./channelReport.ts";
//
// Rules every template follows:
//   * Every payload value is escaped before it lands in HTML (event names,
//     venues, org names and cancel reasons are organizer-written).
//   * Subjects are plain text: raw names, no escaping, no line breaks.
//   * Links are built from the app URL + ids that must be UUIDs, so a payload
//     can't point a link anywhere else.
//   * Prices are all-in (what the buyer paid); organizer mails show counts and
//     totals only, never a buyer's name or email.
//   * Marketing mails (payload.marketing) carry the unsubscribe link; the
//     drain also sends it as List-Unsubscribe (exos_mail.list_unsubscribe).

export type RenderedTemplate =
  | { ok: true; subject: string; html: string }
  | { ok: false; error: string };

type Obj = Record<string, unknown>;

class PayloadError extends Error {}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN = /^[0-9a-f]{64}$/;

// ── value helpers ───────────────────────────────────────────────────────────

export function escapeHtml(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
const esc = escapeHtml;

function isObj(v: unknown): v is Obj {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
function obj(p: Obj, k: string): Obj {
  const v = p[k];
  if (!isObj(v)) throw new PayloadError(`${k} missing`);
  return v;
}
function str(p: Obj, k: string, fallback?: string): string {
  const v = p[k];
  if (typeof v === "string" && v.trim() !== "") return v;
  if (fallback !== undefined) return fallback;
  throw new PayloadError(`${k} missing`);
}
function opt(p: Obj, k: string): string | null {
  const v = p[k];
  return typeof v === "string" && v.trim() !== "" ? v : null;
}
function num(p: Obj, k: string, fallback?: number): number {
  const v = typeof p[k] === "string" ? Number(p[k]) : p[k];
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (fallback !== undefined) return fallback;
  throw new PayloadError(`${k} missing`);
}
function list(p: Obj, k: string): Obj[] {
  const v = p[k];
  return Array.isArray(v) ? v.filter(isObj) : [];
}
function uuid(p: Obj, k: string): string {
  const v = p[k];
  if (typeof v !== "string" || !UUID.test(v)) throw new PayloadError(`${k} is not an id`);
  return v.toLowerCase();
}

/** Plain-text header: no CR/LF or control characters, at most 200 chars. */
export function plainSubject(s: string): string {
  // deno-lint-ignore no-control-regex
  const flat = s.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  return flat.length > 200 ? flat.slice(0, 199) + "…" : flat;
}

export function formatMoney(cents: number, currency: string): string {
  const cur = (currency || "usd").toUpperCase();
  const amount = Math.round(cents) / 100;
  try {
    return new Intl.NumberFormat("en-US", { style: "currency", currency: cur }).format(amount);
  } catch {
    return `${amount.toFixed(2)} ${cur}`;
  }
}

function parts(d: Date, tz: string, o: Intl.DateTimeFormatOptions): Record<string, string> {
  const out: Record<string, string> = {};
  for (const x of new Intl.DateTimeFormat("en-US", { ...o, timeZone: tz }).formatToParts(d)) out[x.type] = x.value;
  return out;
}
function zone(tz: string | null | undefined): string {
  const z = (tz ?? "").trim() || "UTC";
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: z });
    return z;
  } catch {
    return "UTC";
  }
}

/** "Friday, October 2 at 8:00 PM EDT" in the event's zone (UTC when unknown). */
export function formatWhen(iso: string, tz?: string | null): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = parts(d, zone(tz), {
    weekday: "long", month: "long", day: "numeric", hour: "numeric", minute: "2-digit",
    hour12: true, timeZoneName: "short",
  });
  return `${p.weekday}, ${p.month} ${p.day} at ${p.hour}:${p.minute} ${p.dayPeriod} ${p.timeZoneName}`;
}

/** "October 12, 2026" (UTC). */
export function formatDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = parts(d, "UTC", { month: "long", day: "numeric", year: "numeric" });
  return `${p.month} ${p.day}, ${p.year}`;
}

/** "Monday, September 28" (UTC). */
function formatDay(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = parts(d, "UTC", { weekday: "long", month: "long", day: "numeric" });
  return `${p.weekday}, ${p.month} ${p.day}`;
}

// ── building blocks ─────────────────────────────────────────────────────────

interface Ctx {
  app: string;
  p: Obj;
}
interface Out {
  subject: string;
  body: string;
  /** who this mail is for: sets the footer */
  audience: "buyer" | "organizer" | "partner";
  orgName?: string;
}

function href(ctx: Ctx, path: string): string {
  return esc(ctx.app + path);
}
function button(ctx: Ctx, path: string, label: string): string {
  return `<p><a href="${href(ctx, path)}" style="display:inline-block;padding:10px 16px;background:#111;color:#fff;text-decoration:none;border-radius:6px">${esc(label)}</a></p>`;
}

interface Ev {
  id: string;
  name: string;
  when: string;
  where: string;
}
function event(p: Obj): Ev {
  const e = obj(p, "event");
  const venue = [opt(e, "venue_name"), opt(e, "venue_location")].filter(Boolean).join(", ");
  const starts = opt(e, "starts_at");
  return {
    id: uuid(e, "id"),
    name: str(e, "name", "your event"),
    when: starts ? formatWhen(starts, opt(e, "timezone")) : "",
    where: venue,
  };
}
/** "<strong>Name</strong><br>When · Where" (escaped). */
function eventBlock(ev: Ev): string {
  const line = [ev.when, ev.where].filter(Boolean).map(esc).join(" · ");
  return `<p><strong>${esc(ev.name)}</strong>${line ? `<br>${line}` : ""}</p>`;
}
function org(p: Obj): { id: string; name: string } {
  const o = obj(p, "org");
  return { id: uuid(o, "id"), name: str(o, "name", "your organization") };
}
function salesTable(rows: Obj[]): string {
  if (rows.length === 0) return "";
  const tr = rows.map((r) =>
    `<tr><td style="padding:2px 12px 2px 0">${esc(str(r, "name", "Event"))}</td>` +
    `<td style="padding:2px 12px 2px 0;text-align:right">${num(r, "tickets", 0)} ticket${num(r, "tickets", 0) === 1 ? "" : "s"}</td>` +
    `<td style="padding:2px 0;text-align:right">${esc(formatMoney(num(r, "gross_cents", 0), str(r, "currency", "usd")))}</td></tr>`
  ).join("");
  return `<table style="border-collapse:collapse;font-size:14px">${tr}</table>`;
}
function totalsLine(totals: Obj[]): { tickets: number; text: string } {
  const tickets = totals.reduce((n, t) => n + num(t, "tickets", 0), 0);
  const money = totals.map((t) => formatMoney(num(t, "gross_cents", 0), str(t, "currency", "usd"))).join(" + ");
  return { tickets, text: `${tickets} ticket${tickets === 1 ? "" : "s"}${money ? `, ${money}` : ""}` };
}

// Offers, settlements, ticket counts (migs 20261031100000 / 20261031100500).
// These go to people outside the org (agents, tour accountants): links carry
// a 64-hex token and an id that must be a UUID.
function token(p: Obj, k: string): string {
  const v = p[k];
  if (typeof v !== "string" || !TOKEN.test(v)) throw new PayloadError(`${k} missing`);
  return v;
}
/** "$1,000.00 versus 85% of net after expenses" (deal terms as stored). */
function dealLine(t: Obj, cur: string): string {
  const g = formatMoney(num(t, "guarantee_cents", 0), cur);
  const pct = `${num(t, "percentage", 0)}%`;
  switch (opt(t, "deal_type")) {
    case "versus": return `${g} versus ${pct} of net after expenses`;
    case "plus": return `${g} plus ${pct} of net above the split point`;
    case "door": return num(t, "guarantee_cents", 0) > 0 ? `${pct} of net box office, ${g} minimum` : `${pct} of net box office`;
    default: return `${g} flat`;
  }
}
function showDay(d: unknown): string {
  return typeof d === "string" && /^\d{4}-\d{2}-\d{2}$/.test(d) ? formatDay(`${d}T12:00:00Z`) : "";
}

// ── templates ───────────────────────────────────────────────────────────────

const REFUND_TEXT: Record<string, (paid: string, refunded: string) => string> = {
  refunded: (_p, r) => `Your refund of ${r} has been issued. It can take 5 to 10 days to show up on your statement.`,
  partial: (p, r) => `${r} of the ${p} you paid has been refunded so far. We'll email you when the rest is issued.`,
  processing: (p) => `Your refund of ${p} is being processed. We'll email you when it's issued.`,
  pending: (p) => `You paid ${p}. The organizer is refunding orders, and we'll email you when yours is issued.`,
  not_buyer: () => `Any refund goes to the person who bought the tickets.`,
  none: () => `This ticket was free, so there's nothing to refund.`,
};

// Disputes (mig 20261001101000). The dispute lives on the Exos platform's
// Stripe account (destination charges), so the one link out of the app is
// Stripe's own dashboard page for that dispute, built from a checked id.
const DISPUTE_ID = /^(dp|du)_[A-Za-z0-9]{1,200}$/;
const DISPUTE_REASONS: Record<string, string> = {
  bank_cannot_process: "the bank couldn't process the payment",
  credit_not_processed: "the buyer says a promised refund wasn't made",
  customer_initiated: "the buyer asked their bank to reverse it",
  debit_not_authorized: "the buyer says they didn't authorize the debit",
  duplicate: "the buyer says they were charged twice",
  fraudulent: "the cardholder says they didn't make the purchase",
  general: "no specific reason given",
  incorrect_account_details: "incorrect account details",
  insufficient_funds: "insufficient funds",
  product_not_received: "the buyer says they didn't get their tickets",
  product_unacceptable: "the buyer says the event wasn't as described",
  subscription_canceled: "the buyer says they cancelled",
  unrecognized: "the buyer doesn't recognize the charge",
};
function disputeReason(p: Obj): string {
  const r = opt(p, "reason");
  if (!r) return "no reason given";
  return DISPUTE_REASONS[r] ?? r.replace(/_/g, " ");
}
interface DisputeView {
  org: { id: string; name: string };
  ev: Ev | null;
  amount: string;
  fee: string | null;
  stripeUrl: string;
  eventLine: string;
}
function disputeView(ctx: Ctx): DisputeView {
  const o = org(ctx.p);
  const id = str(ctx.p, "dispute_id");
  if (!DISPUTE_ID.test(id)) throw new PayloadError("dispute_id is not a dispute id");
  const cur = str(ctx.p, "currency", "usd");
  const feeCents = num(ctx.p, "fee_cents", 0);
  const ev = isObj(ctx.p.event) ? event(ctx.p) : null;
  return {
    org: o,
    ev,
    amount: formatMoney(num(ctx.p, "amount_cents"), cur),
    fee: feeCents > 0 ? formatMoney(feeCents, cur) : null,
    stripeUrl: `https://dashboard.stripe.com/${ctx.p.livemode === false ? "test/" : ""}disputes/${id}`,
    eventLine: ev ? eventBlock(ev) : "",
  };
}
function disputeLinks(ctx: Ctx, v: DisputeView): string {
  return (v.ev ? button(ctx, `/dashboard/event/${v.ev.id}`, "See it in the event's Money") : button(ctx, "/dashboard", "Your dashboard")) +
    `<p style="color:#666;font-size:13px">Exos staff: <a href="${esc(v.stripeUrl)}">open the dispute in Stripe</a>.</p>`;
}

// Weekly sales by channel (mig 20261029120000). The SPA's Channels card and
// /orgs/:id/channels read the same document (channelReport.ts). The mail shows
// labels only (fixed list, SQL _exos_channel_label), one row per label
// (messageRows): utm_source is buyer-controlled, so no key reaches the mail.
function channelTable(e: EventChannels): string {
  const rows = messageRows(e.sales);
  if (rows.length === 0) return `<p style="color:#666">No sales yet.</p>`;
  const td = `style="padding:2px 10px 2px 0;text-align:right;white-space:nowrap"`;
  const head = `<tr style="color:#666;font-size:12px"><td style="padding:2px 10px 2px 0">Channel</td><td ${td}>This week</td>` +
    `<td ${td}>To date</td><td ${td}>Gross</td><td ${td}>Channel fees</td><td ${td}>Net to you</td></tr>`;
  const row = (r: ChannelRow) =>
    `<tr><td style="padding:2px 10px 2px 0">${esc(r.label)}</td>` +
    `<td ${td}>${r.week ? r.week.tickets : "–"}</td><td ${td}>${r.toDate.tickets}</td>` +
    `<td ${td}>${esc(money(r.toDate.grossCents, r.currency))}</td>` +
    `<td ${td}>${esc(feeText(r.toDate, r.fees, r.currency))}</td>` +
    `<td ${td}>${esc(money(r.toDate.netCents, r.currency))}</td></tr>`;
  return `<table style="border-collapse:collapse;font-size:14px">${head}${rows.map(row).join("")}</table>`;
}

function channelEvent(ctx: Ctx, e: EventChannels): string {
  const when = e.startsAt ? formatWhen(e.startsAt, e.timezone) : "";
  const exos = e.sales.reduce((k, r) => k + (r.toDate.exosFeeCents ?? 0), 0);
  const side = sideCounts(e, "toDate");
  const undated = messageRows(e.sales).filter((r) => !r.dated).map((r) => r.label);
  const extra = [
    side.comps ? plural(side.comps, "comp") : "",
    side.attendees ? `${plural(side.attendees, "imported attendee")} from other lists` : "",
  ].filter(Boolean);
  const note = notReportedNote(e.totals.toDate);
  return `<p style="margin-top:20px"><a href="${href(ctx, `/dashboard/event/${uuid({ id: e.id }, "id")}`)}"><strong>${esc(e.name)}</strong></a>` +
    `${when ? `<br><span style="color:#666">${esc(when)}</span>` : ""}</p>` +
    channelTable(e) +
    `<p style="font-size:13px">This week: ${esc(totalsText(e.totals.week))}. To date: ${esc(totalsText(e.totals.toDate))}.` +
    (exos > 0 ? ` Exos fee to date: ${esc(money(exos, e.currency))} (already taken out of net).` : "") + `</p>` +
    (extra.length ? `<p style="font-size:13px;color:#666">Not sales: ${esc(extra.join(", "))}.</p>` : "") +
    (undated.length
      ? `<p style="font-size:13px;color:#666">${esc(undated.join(", "))}: counts only, without sale dates, so ${undated.length === 1 ? "it's" : "they're"} in "to date" and not in the week.</p>`
      : "") +
    (note ? `<p style="font-size:13px;color:#666">${esc(note)}</p>` : "");
}

const RENDERERS: Record<string, (ctx: Ctx) => Out> = {
  // ── buyer ──
  "event-cancelled": (ctx) => {
    const ev = event(ctx.p);
    const e = obj(ctx.p, "event");
    const orgName = str(e, "org_name", "The organizer");
    const reason = opt(ctx.p, "reason");
    const refund = isObj(ctx.p.refund) ? ctx.p.refund : {};
    const cur = str(refund, "currency", "usd");
    const status = str(refund, "status", "none");
    const say = REFUND_TEXT[status] ?? REFUND_TEXT.none;
    return {
      audience: "buyer",
      subject: `Cancelled: ${ev.name}`,
      body:
        `<p>Sorry: ${esc(orgName)} has cancelled this event.</p>` + eventBlock(ev) +
        (reason ? `<p>From the organizer: “${esc(reason)}”</p>` : "") +
        `<p>${esc(say(formatMoney(num(refund, "paid_cents", 0), cur), formatMoney(num(refund, "refunded_cents", 0), cur)))}</p>` +
        button(ctx, "/my-tickets", "Your tickets"),
    };
  },

  "event-updated": (ctx) => {
    const ev = event(ctx.p);
    const e = obj(ctx.p, "event");
    const doors = opt(e, "doors_at");
    return {
      audience: "buyer",
      subject: `Updated: ${ev.name}`,
      body:
        `<p>${esc(str(e, "org_name", "The organizer"))} changed the details of an event you have tickets for. Here's where things stand now:</p>` +
        eventBlock(ev) +
        (doors ? `<p>Doors open ${esc(formatWhen(doors, opt(e, "timezone")))}.</p>` : "") +
        `<p>Your ticket still works. There's nothing you need to do.</p>` +
        button(ctx, `/event/${ev.id}`, "See the event"),
    };
  },

  // Mig 20260929150000: the organizer moved the event. Old and new time in the
  // event's zone; when refunds are offered, a link per ticket this address may
  // refund (they paid) or release (free / comp), each carrying a 64-hex token
  // for that ticket + reschedule only. Marketplace buyers are sent to the
  // marketplace; a holder someone else paid for is told the refund is theirs.
  "event-rescheduled": (ctx) => {
    const ev = event(ctx.p);
    const e = obj(ctx.p, "event");
    const tz = opt(e, "timezone");
    const orgName = str(e, "org_name", "The organizer");
    const oldAt = opt(ctx.p, "old_starts_at");
    const newAt = opt(ctx.p, "new_starts_at") ?? opt(e, "starts_at");
    const doors = opt(e, "doors_at");
    const reason = opt(ctx.p, "reason");
    const offered = ctx.p.refunds_offered === true;
    const deadline = opt(ctx.p, "refund_deadline");
    const refunds = list(ctx.p, "refunds");
    const releases = list(ctx.p, "releases");
    const more = num(ctx.p, "more_links", 0);
    const marketplace = num(ctx.p, "marketplace", 0);
    const notBuyer = num(ctx.p, "not_buyer", 0);
    const otherPaid = num(ctx.p, "other_paid", 0);
    const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;
    const token = (x: Obj): string => {
      const t = x.token;
      if (typeof t !== "string" || !TOKEN.test(t)) throw new PayloadError("token missing");
      return t;
    };
    const link = (x: Obj, label: string) =>
      `<li><a href="${href(ctx, `/refund?t=${token(x)}`)}">${esc(label)}</a></li>`;
    const refundItems = refunds.map((x) => {
      const amount = formatMoney(num(x, "amount_cents", 0), str(x, "currency", "usd"));
      return link(x, `Get a refund: ${str(x, "tier_name", "Ticket")} (${amount})`);
    }).join("");
    const releaseItems = releases.map((x) => link(x, `Release my ticket: ${str(x, "tier_name", "Ticket")}`)).join("");
    const canAct = offered && (refundItems !== "" || releaseItems !== "");

    let body =
      `<p>${esc(orgName)} changed the date of an event you have tickets for.</p>` +
      `<p><strong>${esc(ev.name)}</strong>` + (ev.where ? `<br>${esc(ev.where)}` : "") + `</p>` +
      (oldAt ? `<p>Was: <s>${esc(formatWhen(oldAt, tz))}</s><br>` : "<p>") +
      (newAt ? `Now: <strong>${esc(formatWhen(newAt, tz))}</strong>` : "") + `</p>` +
      (doors ? `<p>Doors open ${esc(formatWhen(doors, tz))}.</p>` : "") +
      (reason ? `<p>From the organizer: “${esc(reason)}”</p>` : "");
    if (canAct) {
      body +=
        `<p>Your tickets work for the new date. If you can't make it, you can ` +
        (refundItems && releaseItems ? "get a refund or give your free ticket back" : refundItems ? "get a refund" : "give your ticket back") +
        (deadline ? ` until <strong>${esc(formatWhen(deadline, tz))}</strong>` : "") + `.</p>` +
        (refundItems ? `<ul>${refundItems}</ul><p style="color:#666;font-size:13px">A refund goes back to the card you paid with, including tax, and cancels that ticket (also if you gave it to someone).</p>` : "") +
        (releaseItems ? `<ul>${releaseItems}</ul>` : "") +
        (more > 0 ? `<p>${esc(plural(more, "more ticket"))}: sign in to Exos and open Your tickets.</p>` : "");
    } else {
      body += `<p>Your ticket still works for the new date. There's nothing you need to do.</p>`;
    }
    if (marketplace > 0) {
      body += `<p>You bought ${esc(plural(marketplace, "ticket"))} on a resale marketplace. ` +
        (offered ? `Refunds for those go through the marketplace where you bought them.` : `Questions about those go to the marketplace where you bought them.`) + `</p>`;
    }
    if (offered && notBuyer > 0) {
      body += `<p>Someone else paid for ${notBuyer === 1 ? "a ticket you hold" : `${notBuyer} of your tickets`}. ` +
        `A refund goes back to their card, so only they can ask for it.</p>`;
    }
    if (offered && otherPaid > 0) {
      body += `<p>For tickets you didn't buy on Exos, ask ${esc(orgName)} about refunds.</p>`;
    }
    body += button(ctx, `/event/${ev.id}`, "See the event");
    return {
      audience: "buyer",
      subject: `New date: ${ev.name}`,
      body,
    };
  },

  "refund-issued": (ctx) => {
    const ev = event(ctx.p);
    const cur = str(ctx.p, "currency", "usd");
    const amount = formatMoney(num(ctx.p, "amount_cents"), cur);
    const partial = ctx.p.partial === true;
    return {
      audience: "buyer",
      subject: `Refund issued: ${amount} for ${ev.name}`,
      body:
        `<p>We've refunded <strong>${esc(amount)}</strong> for your order for <strong>${esc(ev.name)}</strong>.</p>` +
        `<p>It goes back to the card you paid with and can take 5 to 10 days to show up.</p>` +
        (partial
          ? `<p>Refunded so far: ${esc(formatMoney(num(ctx.p, "refunded_total_cents", 0), cur))} of ${esc(formatMoney(num(ctx.p, "paid_cents", 0), cur))}. Your remaining tickets still work.</p>`
          : "") +
        `<p style="color:#666;font-size:13px">Order reference: ${esc(str(ctx.p, "order_ref", "-"))}</p>` +
        button(ctx, "/my-tickets", "Your tickets"),
    };
  },

  "post-event": (ctx) => {
    const ev = event(ctx.p);
    const o = org(ctx.p);
    const next = list(ctx.p, "next_events").slice(0, 3);
    const items = next.map((n) => {
      const when = opt(n, "starts_at") ? formatWhen(String(n.starts_at), opt(n, "timezone")) : "";
      return `<li><a href="${href(ctx, `/event/${uuid(n, "id")}`)}">${esc(str(n, "name", "Event"))}</a>${when ? `, ${esc(when)}` : ""}</li>`;
    }).join("");
    return {
      audience: "buyer",
      orgName: o.name,
      subject: `Thanks for coming to ${ev.name}`,
      body:
        `<p>Thanks for being at <strong>${esc(ev.name)}</strong>. We hope it was a good one.</p>` +
        (items ? `<p>Coming up from ${esc(o.name)}:</p><ul>${items}</ul>` : "") +
        (ctx.p.following === true
          ? ""
          : `<p>Follow ${esc(o.name)} on Exos to hear about their next events first.</p>` +
            button(ctx, `/organizer/${o.id}`, `Follow ${o.name}`)),
    };
  },

  // ── organizer ──
  "event-published": (ctx) => {
    const ev = event(ctx.p);
    const e = obj(ctx.p, "event");
    return {
      audience: "organizer",
      orgName: str(e, "org_name", ""),
      subject: `Published: ${ev.name}`,
      body:
        `<p>Your event is live on Exos. People can find it and buy tickets once a tier is on sale.</p>` +
        eventBlock(ev) +
        button(ctx, `/event/${ev.id}`, "See the public page") +
        `<p><a href="${href(ctx, `/dashboard/event/${ev.id}/promote`)}">Get share links and promo tools</a></p>`,
    };
  },

  "inventory-low": (ctx) => {
    const ev = event(ctx.p);
    const t = obj(ctx.p, "tier");
    const tier = str(t, "name", "A tier");
    const left = num(t, "remaining");
    return {
      audience: "organizer",
      orgName: str(obj(ctx.p, "event"), "org_name", ""),
      subject: `Almost sold out: ${tier} for ${ev.name}`,
      body:
        `<p><strong>${esc(tier)}</strong> for <strong>${esc(ev.name)}</strong> has ${left} of ${num(t, "capacity")} left.</p>` +
        `<p>To sell more, raise the capacity or add another tier.</p>` +
        button(ctx, `/edit-event/${ev.id}`, "Open the event"),
    };
  },

  "inventory-sold-out": (ctx) => {
    const ev = event(ctx.p);
    const t = obj(ctx.p, "tier");
    const tier = str(t, "name", "A tier");
    return {
      audience: "organizer",
      orgName: str(obj(ctx.p, "event"), "org_name", ""),
      subject: `Sold out: ${tier} for ${ev.name}`,
      body:
        `<p><strong>${esc(tier)}</strong> for <strong>${esc(ev.name)}</strong> is sold out: ${num(t, "sold")} of ${num(t, "capacity")}.</p>` +
        `<p>To sell more, raise the capacity in the event editor. People on the waitlist get the first offer on new seats.</p>` +
        button(ctx, `/edit-event/${ev.id}`, "Open the event"),
    };
  },

  // A fixed block handed back to the organizer's primary platform (mig
  // 20261029160000). Counts only: Exos can't write to that platform, so the
  // organizer puts these tickets back on sale there.
  "fixed-block-released": (ctx) => {
    const ev = event(ctx.p);
    const platform = str(ctx.p, "platform", "your ticketing platform");
    const total = num(ctx.p, "total_returned", 0);
    const pending = num(ctx.p, "total_pending", 0);
    const unit = (t: Obj, n: number) => {
      const table = str(t, "kind", "standard") === "table";
      const party = num(t, "party_size", 1);
      return table
        ? `${n} table${n === 1 ? "" : "s"}${party > 1 ? ` of ${party}` : ""}`
        : `${n} ticket${n === 1 ? "" : "s"}`;
    };
    const rows = list(ctx.p, "tiers").map((t) =>
      `<tr><td style="padding:2px 12px 2px 0">${esc(str(t, "name", "Ticket"))}</td>` +
      `<td style="padding:2px 12px 2px 0;text-align:right"><strong>${esc(unit(t, num(t, "returned", 0)))}</strong></td>` +
      `<td style="padding:2px 0;color:#666">sold ${num(t, "sold", 0)} of ${num(t, "block", 0)} on Exos</td></tr>`
    ).join("");
    return {
      audience: "organizer",
      orgName: str(obj(ctx.p, "event"), "org_name", ""),
      subject: `Put ${total} ticket${total === 1 ? "" : "s"} back on ${platform}: ${ev.name}`,
      body:
        eventBlock(ev) +
        `<p>Exos has stopped selling its block for this event. Put these back on sale on <strong>${esc(platform)}</strong> ` +
        `(Exos can't change your listing there):</p>` +
        (rows ? `<table style="border-collapse:collapse;font-size:14px">${rows}</table>` : "") +
        (pending > 0
          ? `<p>${pending} more ${pending === 1 ? "is" : "are"} still in a checkout or on a marketplace. If they don't sell, the event page shows them as "put back".</p>`
          : "") +
        `<p>Tickets sold on Exos are on your Exos door list. For the rest, import ${esc(platform)}'s attendee export into a guest list.</p>` +
        button(ctx, `/dashboard/event/${ev.id}`, "Open the event"),
    };
  },

  "payout-sent": (ctx) => {
    const o = org(ctx.p);
    const amount = formatMoney(num(ctx.p, "amount_cents"), str(ctx.p, "currency"));
    const ref = opt(ctx.p, "reference");
    return {
      audience: "organizer",
      orgName: o.name,
      subject: `Payout sent: ${amount}`,
      body:
        `<p>We sent ${esc(o.name)} a payout of <strong>${esc(amount)}</strong> for ${esc(str(ctx.p, "period"))}.</p>` +
        `<p>Banks usually take 1 to 3 business days to show it.</p>` +
        (ref ? `<p style="color:#666;font-size:13px">Reference: ${esc(ref)}</p>` : "") +
        button(ctx, "/dashboard", "Your dashboard"),
    };
  },

  "payout-pending": (ctx) => {
    const o = org(ctx.p);
    const amount = formatMoney(num(ctx.p, "amount_cents"), str(ctx.p, "currency"));
    return {
      audience: "organizer",
      orgName: o.name,
      subject: `Payout on the way: ${amount}`,
      body:
        `<p>A payout of <strong>${esc(amount)}</strong> for ${esc(str(ctx.p, "period"))} is being prepared for ${esc(o.name)}.</p>` +
        `<p>We'll email you again when it's sent.</p>` +
        button(ctx, "/dashboard", "Your dashboard"),
    };
  },

  "dispute-opened": (ctx) => {
    const v = disputeView(ctx);
    const inquiry = str(ctx.p, "status", "needs_response").startsWith("warning_");
    const due = opt(ctx.p, "evidence_due_by");
    const dueText = due ? formatWhen(due, "UTC") : "";
    return {
      audience: "organizer",
      orgName: v.org.name,
      subject: `${inquiry ? "Payment inquiry" : "Chargeback"}: ${v.amount}${v.ev ? ` for ${v.ev.name}` : ""}`,
      body:
        `<p>A buyer's bank ${inquiry ? "opened an inquiry into" : "disputed"} a <strong>${esc(v.amount)}</strong> payment` +
        `${v.ev ? "" : ` to ${esc(v.org.name)}`}. Reason: ${esc(disputeReason(ctx.p))}.</p>` +
        v.eventLine +
        (inquiry ? "" : `<p>The bank has taken the money back while it decides${v.fee ? `, and Stripe charged a ${esc(v.fee)} dispute fee` : ""}. The tickets stay valid in the meantime.</p>`) +
        (dueText
          ? `<p><strong>Evidence is due ${esc(dueText)}.</strong> Send the Exos team anything that shows the buyer got what they paid for: the check-in record, a ticket transfer, messages with the buyer, your refund policy. We submit it to the bank from Stripe.</p>`
          : `<p>Send the Exos team anything that shows the buyer got what they paid for: the check-in record, a ticket transfer, messages with the buyer, your refund policy.</p>`) +
        disputeLinks(ctx, v),
    };
  },

  "dispute-won": (ctx) => {
    const v = disputeView(ctx);
    return {
      audience: "organizer",
      orgName: v.org.name,
      subject: `Chargeback won: ${v.amount}${v.ev ? ` for ${v.ev.name}` : ""}`,
      body:
        `<p>The bank decided in your favour: the <strong>${esc(v.amount)}</strong> dispute is closed and the money is back.</p>` +
        v.eventLine +
        (v.fee ? `<p>Stripe's ${esc(v.fee)} dispute fee isn't returned.</p>` : "") +
        disputeLinks(ctx, v),
    };
  },

  "dispute-lost": (ctx) => {
    const v = disputeView(ctx);
    const cur = str(ctx.p, "currency", "usd");
    const recovery = str(ctx.p, "recovery_status", "not_recovered");
    const candidate = formatMoney(num(ctx.p, "recovery_candidate_cents", 0), cur);
    return {
      audience: "organizer",
      orgName: v.org.name,
      subject: `Chargeback lost: ${v.amount}${v.ev ? ` for ${v.ev.name}` : ""}`,
      body:
        `<p>The bank sided with the buyer: the <strong>${esc(v.amount)}</strong> payment went back to them, and the order's tickets are now void.</p>` +
        v.eventLine +
        (recovery === "recovery_pending"
          ? `<p>Under your Exos terms, ${esc(candidate)} (the amount${v.fee ? " plus the dispute fee" : ""}) can be taken from a later payout.</p>`
          : `<p>Nothing is taken from your payouts for this one.</p>`) +
        disputeLinks(ctx, v),
    };
  },

  "fee-free-ending": (ctx) => {
    const o = org(ctx.p);
    const until = formatDate(str(ctx.p, "fee_free_until"));
    const pct = num(ctx.p, "fee_bps", 300) / 100;
    const days = num(ctx.p, "days_left", 1);
    const soon = str(ctx.p, "stage", "14d") === "1d";
    return {
      audience: "organizer",
      orgName: o.name,
      subject: soon ? `Your Exos free months end ${until}` : `Your Exos free months end in ${days} days`,
      body:
        `<p>${esc(o.name)} pays no Exos fee on sales until <strong>${esc(until)}</strong>.</p>` +
        `<p>After that, Exos keeps ${pct}% of each sale. It applies to new sales automatically, so there's nothing to do.</p>` +
        button(ctx, `/orgs/${o.id}/settings`, "Your org settings"),
    };
  },

  "org-welcome": (ctx) => {
    const o = org(ctx.p);
    const until = opt(ctx.p, "fee_free_until");
    return {
      audience: "organizer",
      orgName: o.name,
      subject: `Welcome to Exos, ${o.name}`,
      body:
        `<p>${esc(o.name)} is set up on Exos. Three steps get you selling:</p>` +
        `<ol><li>Create your first event.</li><li>Connect Stripe so ticket money goes to your bank.</li><li>Share your event link.</li></ol>` +
        (until ? `<p>There's no Exos fee on your sales until ${esc(formatDate(until))}.</p>` : "") +
        button(ctx, "/create-event", "Create an event"),
    };
  },

  "org-first-event": (ctx) => {
    const o = org(ctx.p);
    return {
      audience: "organizer",
      orgName: o.name,
      subject: `Ready to put your first event on sale?`,
      body:
        `<p>${esc(o.name)} doesn't have an event yet. It takes a few minutes: add a date, a venue and a ticket tier, and you get a page to share.</p>` +
        button(ctx, "/create-event", "Create an event"),
    };
  },

  "org-connect-stripe": (ctx) => {
    const o = org(ctx.p);
    return {
      audience: "organizer",
      orgName: o.name,
      subject: `Connect Stripe to get paid for ${o.name}`,
      body:
        `<p>To sell paid tickets, connect a Stripe account. Ticket money then goes straight to your bank.</p>` +
        (ctx.p.has_event === true ? "" : `<p>Free events work without it.</p>`) +
        button(ctx, `/orgs/${o.id}/settings`, "Connect Stripe"),
    };
  },

  "org-sales-digest": (ctx) => {
    const o = org(ctx.p);
    const day = formatDay(str(ctx.p, "from"));
    const t = totalsLine(list(ctx.p, "totals"));
    return {
      audience: "organizer",
      orgName: o.name,
      subject: `${o.name}: ${t.tickets} ticket${t.tickets === 1 ? "" : "s"} sold ${day}`,
      body:
        `<p>Sales for ${esc(o.name)} on ${esc(day)} (UTC):</p>` +
        salesTable(list(ctx.p, "events")) +
        `<p><strong>Total:</strong> ${esc(t.text)}</p>` +
        button(ctx, "/dashboard", "Your dashboard"),
    };
  },

  "org-weekly-summary": (ctx) => {
    const o = org(ctx.p);
    const from = formatDay(str(ctx.p, "from"));
    const to = formatDay(new Date(new Date(str(ctx.p, "to")).getTime() - 86_400_000).toISOString());
    const events = list(ctx.p, "events");
    const t = totalsLine(list(ctx.p, "totals"));
    const checkins = num(ctx.p, "checkins", 0);
    const up = list(ctx.p, "upcoming").map((u) => {
      const cap = num(u, "capacity", 0);
      const when = opt(u, "starts_at") ? formatWhen(String(u.starts_at), opt(u, "timezone")) : "";
      return `<li><a href="${href(ctx, `/dashboard/event/${uuid(u, "id")}`)}">${esc(str(u, "name", "Event"))}</a>` +
        `${when ? `, ${esc(when)}` : ""}: ${num(u, "sold", 0)}${cap > 0 ? ` of ${cap}` : ""} sold</li>`;
    }).join("");
    return {
      audience: "organizer",
      orgName: o.name,
      subject: `${o.name}: your week on Exos`,
      body:
        `<p>${esc(o.name)}, ${esc(from)} to ${esc(to)} (UTC):</p>` +
        (events.length ? salesTable(events) + `<p><strong>Total:</strong> ${esc(t.text)}</p>` : `<p>No sales this week.</p>`) +
        (checkins > 0 ? `<p>${checkins} check-in${checkins === 1 ? "" : "s"} at the door.</p>` : "") +
        (up ? `<p>Coming up in the next two weeks:</p><ul>${up}</ul>` : "") +
        button(ctx, "/dashboard", "Your dashboard"),
    };
  },

  "org-channel-report": (ctx) => {
    const o = org(ctx.p);
    const rep = parseChannelReport(ctx.p);
    if (!rep) throw new PayloadError("report missing");
    const week = weekLabel(str(ctx.p, "from"), str(ctx.p, "to"));
    const t = sumTickets(rep.totals.week);
    return {
      audience: "organizer",
      orgName: o.name,
      subject: `${o.name}: ${plural(t, "ticket")} by channel, ${week}`,
      body:
        `<p>${esc(o.name)}: where your tickets sold ${esc(week)} (UTC) and to date, for events from the last week and the next 60 days.</p>` +
        `<p><strong>This week:</strong> ${esc(totalsText(rep.totals.week))}<br><strong>To date:</strong> ${esc(totalsText(rep.totals.toDate))}</p>` +
        rep.events.map((e) => channelEvent(ctx, e)).join("") +
        (rep.moreEvents > 0 ? `<p>And ${plural(rep.moreEvents, "more event")} on your dashboard.</p>` : "") +
        `<p style="font-size:13px;color:#666">Net to you is after each channel's fees and the Exos fee. Comps and imported lists aren't sales and aren't in the totals.</p>` +
        button(ctx, `/orgs/${o.id}/channels`, "All channels"),
    };
  },
  "offer-sent": (ctx) => {
    const o = org(ctx.p);
    const offer = obj(ctx.p, "offer");
    const id = uuid(offer, "id");
    const t = token(ctx.p, "token");
    const cur = str(offer, "currency", "USD");
    const terms: Obj = isObj(offer.terms) ? offer.terms : {};
    const dates = (Array.isArray(offer.dates) ? offer.dates : []).map(showDay).filter(Boolean);
    const venue = opt(offer, "venue");
    const expires = opt(offer, "expires_at");
    const agent = opt(offer, "agent_name");
    const artist = str(offer, "artist_name", "your artist");
    const bonuses = list(terms, "bonuses").map((b) => `${formatMoney(num(b, "amount_cents", 0), cur)} at ${num(b, "sold", 0)} tickets`);
    const rows: [string, string][] = [["Dates", dates.join("; ") || "To be confirmed"]];
    if (venue) rows.push(["Venue", venue]);
    rows.push(["Deal", dealLine(terms, cur)]);
    if (bonuses.length) rows.push(["Bonuses", bonuses.join("; ")]);
    if (num(terms, "deposit_cents", 0) > 0) rows.push(["Deposit", formatMoney(num(terms, "deposit_cents", 0), cur)]);
    return {
      audience: "partner",
      orgName: o.name,
      subject: `Offer from ${o.name}: ${artist}${dates[0] ? `, ${dates[0]}` : ""}`,
      body:
        `<p>${agent ? `${esc(agent)}, ` : ""}${esc(o.name)} sent an offer for ${esc(artist)}.</p>` +
        `<table style="border-collapse:collapse;font-size:14px">${rows.map(([k, v]) =>
          `<tr><td style="padding:2px 12px 2px 0;color:#666">${esc(k)}</td><td style="padding:2px 0">${esc(v)}</td></tr>`).join("")}</table>` +
        `<p>Read the full offer and accept or decline it here (no account needed):</p>` +
        button(ctx, `/offer/${id}?t=${t}`, "Review the offer") +
        (expires ? `<p style="color:#666;font-size:13px">The offer expires ${esc(formatWhen(expires))}.</p>` : ""),
    };
  },

  "settlement-finalized": (ctx) => {
    const o = org(ctx.p);
    const ev = event(ctx.p);
    const t = token(ctx.p, "token");
    return {
      audience: "partner",
      orgName: o.name,
      subject: `Settlement: ${ev.name}`,
      body:
        `<p>${esc(o.name)} finalized the settlement for this show:</p>` + eventBlock(ev) +
        button(ctx, `/settlement/${ev.id}?t=${t}`, "See the settlement") +
        `<p style="color:#666;font-size:13px">The page has the box office, each act's deal worked through and the venue's share, with a PDF.</p>`,
    };
  },

  "ticket-counts": (ctx) => {
    const o = org(ctx.p);
    const c = obj(ctx.p, "counts");
    const ev = event(c);
    const cur = str(c, "currency", "USD");
    const t = token(ctx.p, "optout_token");
    const tiers = list(c, "tiers").map((r) =>
      `<tr><td style="padding:2px 12px 2px 0">${esc(str(r, "name", "Tickets"))}</td>` +
      `<td style="padding:2px 12px 2px 0;text-align:right">${num(r, "paid", 0)}</td>` +
      `<td style="padding:2px 0;text-align:right">${num(r, "comps", 0)}</td></tr>`).join("");
    const elsewhere = list(c, "sold_elsewhere").map((x) =>
      `${num(x, "sold", 0)} sold elsewhere (${esc(formatMoney(num(x, "gross_cents", 0), str(x, "currency", cur)))})`);
    const pct = c.attendance_percent === null || c.attendance_percent === undefined ? null : num(c, "attendance_percent", 0);
    const cap = num(c, "capacity", 0);
    const who = opt(ctx.p, "recipient_name");
    return {
      audience: "partner",
      orgName: o.name,
      subject: `Ticket counts: ${ev.name} (${num(c, "paid_sold", 0)} sold)`,
      body:
        `<p>${who ? `${esc(who)}, here` : "Here"} are the latest numbers from ${esc(o.name)}:</p>` +
        eventBlock(ev) +
        (tiers ? `<table style="border-collapse:collapse;font-size:14px"><tr><th style="text-align:left;padding:2px 12px 2px 0">Ticket type</th>` +
          `<th style="text-align:right;padding:2px 12px 2px 0">Sold</th><th style="text-align:right;padding:2px 0">Comps</th></tr>${tiers}</table>` : "") +
        `<p><strong>${num(c, "paid_sold", 0)} sold</strong>, ${num(c, "comps", 0)} comps, ` +
        `${esc(formatMoney(num(c, "gross_cents", 0), cur))} gross; ${num(c, "sold_last_24h", 0)} in the last 24 hours.` +
        (pct !== null && cap > 0 ? ` ${pct}% of ${cap} capacity.` : "") + `</p>` +
        (elsewhere.length ? `<p>${elsewhere.join("<br>")}</p>` : "") +
        `<p style="color:#888;font-size:12px"><a href="${href(ctx, `/ticket-counts/opt-out?t=${t}`)}">Stop these emails</a> for this show.</p>`,
    };
  },
};

export const PAYLOAD_TEMPLATES = Object.keys(RENDERERS);

function footer(ctx: Ctx, out: Out): string {
  const lines: string[] = [];
  if (out.audience === "partner") {
    lines.push(`You're getting this from ${esc(out.orgName ?? "an organizer")} through Exos.`);
  }
  if (out.audience === "organizer") {
    lines.push(out.orgName
      ? `You're getting this because you help run ${esc(out.orgName)} on Exos.`
      : `You're getting this because you help run an organization on Exos.`);
  }
  if (ctx.p.marketing === true) {
    const token = ctx.p.unsubscribe_token;
    if (typeof token !== "string" || !TOKEN.test(token)) throw new PayloadError("unsubscribe_token missing");
    lines.push(
      `<a href="${href(ctx, `/unsubscribe?t=${token}`)}">Unsubscribe</a> from follow-up emails like this one. ` +
        `Tickets, receipts and event changes still arrive.`,
    );
  }
  return lines.length ? `<p style="color:#888;font-size:12px">${lines.join("<br>")}</p>` : "";
}

/**
 * Render a payload row. appUrl must already be normalized (normalizeAppUrl in
 * mail-render.ts): every template links into the app, so no URL = no send.
 */
export function renderTemplate(template: string, payload: unknown, appUrl: string | null): RenderedTemplate {
  if (!appUrl) return { ok: false, error: "EXOS_APP_URL unset or invalid; mail links into the app" };
  const fn = Object.prototype.hasOwnProperty.call(RENDERERS, template) ? RENDERERS[template] : undefined;
  if (!fn) return { ok: false, error: `no renderer for template ${template}` };
  if (!isObj(payload)) return { ok: false, error: `${template}: payload is not an object` };
  const ctx: Ctx = { app: appUrl.replace(/\/+$/, ""), p: payload };
  try {
    const out = fn(ctx);
    const html =
      `<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#111;max-width:560px">` +
      out.body + footer(ctx, out) + `</div>`;
    return { ok: true, subject: plainSubject(out.subject), html };
  } catch (e) {
    if (e instanceof PayloadError) return { ok: false, error: `${template}: ${e.message}` };
    return { ok: false, error: `${template}: render failed: ${String(e).slice(0, 200)}` };
  }
}
