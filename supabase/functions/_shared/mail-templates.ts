// Payload-rendered Exos mail (mig 20260929071000), used by exos-mail-drain.
//
// Rows queued by exos_mail_enqueue carry a JSON payload and an empty html;
// the drain calls renderTemplate() to build the subject and body. Pure and
// import-free, so Deno and EXP's vitest (src/lib/mailTemplates.test.ts) both
// load it.
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
  audience: "buyer" | "organizer";
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

// ── templates ───────────────────────────────────────────────────────────────

const REFUND_TEXT: Record<string, (paid: string, refunded: string) => string> = {
  refunded: (_p, r) => `Your refund of ${r} has been issued. It can take 5 to 10 days to show up on your statement.`,
  partial: (p, r) => `${r} of the ${p} you paid has been refunded so far. We'll email you when the rest is issued.`,
  processing: (p) => `Your refund of ${p} is being processed. We'll email you when it's issued.`,
  pending: (p) => `You paid ${p}. The organizer is refunding orders, and we'll email you when yours is issued.`,
  not_buyer: () => `Any refund goes to the person who bought the tickets.`,
  none: () => `This ticket was free, so there's nothing to refund.`,
};

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
};

export const PAYLOAD_TEMPLATES = Object.keys(RENDERERS);

function footer(ctx: Ctx, out: Out): string {
  const lines: string[] = [];
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
