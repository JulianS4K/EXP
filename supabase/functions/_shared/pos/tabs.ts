// Venue POS: tab math. PURE, integer cents. A tab (exos_pos_tabs) is tied to
// a ticket or a wristband; orders ring onto it through the night and it
// closes when nothing is left to pay (exos_pos_close_tab, mig 20260929074000).

export type PosOrderStatus = 'open' | 'paid' | 'void' | 'refunded';

export interface TabOrder {
  status: PosOrderStatus;
  totalCents: number;
  /** Tenders applied so far (tips excluded). */
  paidCents: number;
  tipCents: number;
}

export interface TabBalance {
  orders: number;
  totalCents: number;
  paidCents: number;
  dueCents: number;
  tipCents: number;
  /** True when every order is paid or void (empty open orders are voided at close). */
  canClose: boolean;
}

/** Void and refunded orders don't count toward what the guest owes. */
export function tabBalance(orders: readonly TabOrder[]): TabBalance {
  let total = 0, paid = 0, tips = 0, count = 0;
  for (const o of orders) {
    if (o.status === 'void' || o.status === 'refunded') continue;
    if (o.status === 'open' && o.totalCents === 0) continue; // voided at close
    count += 1;
    total += o.totalCents;
    paid += Math.min(o.paidCents, o.totalCents);
    tips += o.tipCents;
  }
  const due = total - paid;
  return { orders: count, totalCents: total, paidCents: paid, dueCents: due, tipCents: tips, canClose: due === 0 };
}

/**
 * Would ringing `addCents` more take the tab over its limit? The limit is the
 * house's open-tab cap, or a card pre-authorization amount once the terminal
 * is wired (OPERATOR DECISION: pre-auth or cash-deposit tabs, docs/pos.md).
 * null = no limit.
 */
export function overTabLimit(balance: Pick<TabBalance, 'dueCents'>, addCents: number, limitCents: number | null): boolean {
  if (limitCents == null) return false;
  return balance.dueCents + Math.max(addCents, 0) > limitCents;
}

/** What a tab payment of `amountCents` covers, oldest open order first (the fan-out, later in SQL). */
export function allocateTabPayment(
  orders: readonly (TabOrder & { id: string })[],
  amountCents: number,
): { orderId: string; amountCents: number }[] {
  let left = Math.max(Math.round(amountCents), 0);
  const out: { orderId: string; amountCents: number }[] = [];
  for (const o of orders) {
    if (left <= 0) break;
    if (o.status !== 'open') continue;
    const due = o.totalCents - o.paidCents;
    if (due <= 0) continue;
    const take = Math.min(due, left);
    out.push({ orderId: o.id, amountCents: take });
    left -= take;
  }
  return out;
}
