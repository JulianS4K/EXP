// "Money so far" for one event (mig 20261102150000, exos_event_money_so_far):
// the end-of-night summary. Pure; the RPC wrapper lives in ./fastPayouts.ts.

export interface MoneySoFar {
  event_id: string;
  name: string | null;
  currency: string;
  starts_at: string | null;
  timezone: string | null;
  online: {
    orders: number; gross_cents: number; fees_cents: number; tax_cents: number; refunded_cents: number;
    net_cents: number; stripe_net_cents: number; paypal_net_cents: number; last_hour_gross_cents: number;
  };
  door: { cash_cents: number; card_cents: number; comp_cents: number; tips_cents: number };
  tickets: { paid: number; free: number; comps: number; phone_rsvps: number; checked_in: number; voided: number };
  promoters: { owed_cents: number; paid_cents: number; tickets: number };
  as_of: string;
}

const n = (v: unknown) => (Number.isFinite(Number(v)) ? Math.trunc(Number(v)) : 0);

/** Whole-number cents everywhere, missing blocks as zeros. */
export function normalizeMoneySoFar(raw: any): MoneySoFar | null {
  if (!raw || typeof raw !== 'object') return null;
  const o = raw.online ?? {}, d = raw.door ?? {}, t = raw.tickets ?? {}, p = raw.promoters ?? {};
  return {
    event_id: String(raw.event_id ?? ''), name: raw.name ?? null, currency: String(raw.currency || 'usd').toLowerCase(),
    starts_at: raw.starts_at ?? null, timezone: raw.timezone ?? null,
    online: {
      orders: n(o.orders), gross_cents: n(o.gross_cents), fees_cents: n(o.fees_cents), tax_cents: n(o.tax_cents),
      refunded_cents: n(o.refunded_cents), net_cents: n(o.net_cents), stripe_net_cents: n(o.stripe_net_cents),
      paypal_net_cents: n(o.paypal_net_cents), last_hour_gross_cents: n(o.last_hour_gross_cents),
    },
    door: { cash_cents: n(d.cash_cents), card_cents: n(d.card_cents), comp_cents: n(d.comp_cents), tips_cents: n(d.tips_cents) },
    tickets: {
      paid: n(t.paid), free: n(t.free), comps: n(t.comps), phone_rsvps: n(t.phone_rsvps),
      checked_in: n(t.checked_in), voided: n(t.voided),
    },
    promoters: { owed_cents: n(p.owed_cents), paid_cents: n(p.paid_cents), tickets: n(p.tickets) },
    as_of: String(raw.as_of ?? ''),
  };
}

/** Everything the organizer takes home tonight: online net + door (cash and card), less promoter commission still owed. */
export function takeHomeCents(m: MoneySoFar): number {
  return m.online.net_cents + m.door.cash_cents + m.door.card_cents - m.promoters.owed_cents;
}

/** Tickets in the room or still coming. */
export function admitted(m: MoneySoFar): number {
  return m.tickets.paid + m.tickets.free + m.tickets.comps;
}

/** A plain-text summary to paste in a group chat. */
export function moneySoFarText(m: MoneySoFar, fmt: (cents: number) => string): string {
  const lines = [
    `${m.name ?? 'Event'}: money so far`,
    `Online: ${fmt(m.online.gross_cents)} gross from ${m.online.orders} order${m.online.orders === 1 ? '' : 's'}` +
      `, ${fmt(m.online.fees_cents)} fees, ${fmt(m.online.refunded_cents)} refunded = ${fmt(m.online.net_cents)} to you`,
  ];
  if (m.online.paypal_net_cents) lines.push(`  of which PayPal (Exos pays it out): ${fmt(m.online.paypal_net_cents)}`);
  if (m.door.cash_cents || m.door.card_cents || m.door.tips_cents) {
    lines.push(`Door: ${fmt(m.door.cash_cents)} cash, ${fmt(m.door.card_cents)} card, ${fmt(m.door.tips_cents)} tips`);
  }
  if (m.promoters.owed_cents || m.promoters.paid_cents) {
    lines.push(`Promoters: ${fmt(m.promoters.owed_cents)} owed, ${fmt(m.promoters.paid_cents)} paid`);
  }
  lines.push(`Take-home so far: ${fmt(takeHomeCents(m))}`);
  lines.push(`Tickets: ${m.tickets.paid} paid, ${m.tickets.free} free (${m.tickets.phone_rsvps} by phone), ${m.tickets.comps} comps; ${m.tickets.checked_in} checked in`);
  return lines.join('\n');
}
