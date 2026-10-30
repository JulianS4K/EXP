// Split with friends, restaurant-style (KANBAN "Group buy: split with
// friends"; mig 20261031220000). The host bought every ticket in one normal
// checkout. Each friend gets their ticket (an Exos transfer claim link) and a
// prefilled Venmo link to pay the host back, with Cash App as a backup. Exos
// never touches the friends' money: "paid" is the host's own checkbox.
//
// The Venmo pay link format (venmo.com/<user>?txn=pay&amount=&note=) isn't
// documented by Venmo. If it stops prefilling, the message still carries the
// @handle and the amount, so a friend can pay by hand (fallbackLine).

import { supabase } from './supabase';

/** Split `totalCents` into `n` shares that differ by at most a cent; the first ones take the extra cents. */
export function evenSplit(totalCents: number, n: number): number[] {
  if (!Number.isInteger(totalCents) || totalCents < 0 || !Number.isInteger(n) || n < 1) return [];
  const base = Math.floor(totalCents / n);
  const extra = totalCents - base * n;
  return Array.from({ length: n }, (_, i) => base + (i < extra ? 1 : 0));
}

/**
 * The friends' shares when the host keeps `hostTickets` of `tickets` and the
 * order cost `totalCents`: every ticket costs the same share of the total,
 * the host keeps theirs, and the remainder cents go to the host (never a
 * friend paying more than an even split).
 */
export function friendShares(totalCents: number, tickets: number, friends: number): number[] {
  if (friends < 1 || friends > tickets) return [];
  const perTicket = evenSplit(totalCents, tickets);
  // The largest shares (with the extra cent) stay with the host.
  return perTicket.slice(tickets - friends);
}

export const VENMO_HANDLE_RE = /^[A-Za-z0-9_-]{2,30}$/;
export const CASHTAG_RE = /^[A-Za-z][A-Za-z0-9_]{0,20}$/;

export function normalizeVenmo(h: string): string | null {
  const v = h.trim().replace(/^@/, '');
  return VENMO_HANDLE_RE.test(v) ? v : null;
}

export function normalizeCashtag(h: string): string | null {
  const v = h.trim().replace(/^\$/, '');
  return CASHTAG_RE.test(v) ? v : null;
}

const dollars = (cents: number) => (cents / 100).toFixed(2);

/** Prefilled Venmo "pay" link to the host. */
export function venmoPayUrl(handle: string, cents: number, note: string): string | null {
  const h = normalizeVenmo(handle);
  if (!h || cents <= 0) return null;
  const q = new URLSearchParams({ txn: 'pay', amount: dollars(cents), note: note.slice(0, 100) });
  return `https://venmo.com/${encodeURIComponent(h)}?${q.toString()}`;
}

/** Cash App link to the host with the amount ($cashtag/12.50). */
export function cashAppUrl(tag: string, cents: number): string | null {
  const t = normalizeCashtag(tag);
  if (!t || cents <= 0) return null;
  return `https://cash.app/$${t}/${dollars(cents)}`;
}

/** What the host's text says when the link doesn't prefill: handle + amount. */
export function fallbackLine(opts: { venmo?: string | null; cashapp?: string | null; cents: number }): string {
  const parts: string[] = [];
  const v = opts.venmo ? normalizeVenmo(opts.venmo) : null;
  const c = opts.cashapp ? normalizeCashtag(opts.cashapp) : null;
  if (v) parts.push(`Venmo @${v}`);
  if (c) parts.push(`Cash App $${c}`);
  return `$${dollars(opts.cents)} to ${parts.join(' or ') || 'me'}`;
}

/** The one text each friend gets: their ticket link, then how to pay the host back. */
export function friendMessage(opts: {
  friendName: string;
  eventTitle: string;
  claimUrl: string | null;
  cents: number;
  venmo?: string | null;
  cashapp?: string | null;
}): string {
  const note = `${opts.eventTitle} ticket`;
  const lines = [`Hey ${opts.friendName.split(' ')[0] || 'there'}! Your ticket for ${opts.eventTitle}:`];
  lines.push(opts.claimUrl ?? '(I\'ll send it as soon as you\'ve paid)');
  if (opts.cents > 0) {
    lines.push(`Your share: ${fallbackLine(opts)}.`);
    const v = opts.venmo ? venmoPayUrl(opts.venmo, opts.cents, note) : null;
    const c = opts.cashapp ? cashAppUrl(opts.cashapp, opts.cents) : null;
    if (v) lines.push(`Venmo: ${v}`);
    if (c) lines.push(`Cash App: ${c}`);
  }
  return lines.join('\n');
}

/** An sms: link that opens the host's own messages app with the text filled in. */
export function smsUrl(phone: string | null | undefined, body: string): string {
  const to = (phone ?? '').replace(/[^0-9+]/g, '');
  return `sms:${to}?&body=${encodeURIComponent(body)}`;
}

export function totalShares(shares: readonly { amountCents: number }[]): number {
  return shares.reduce((n, s) => n + s.amountCents, 0);
}

// ── API (exos_split_* RPCs; the host's JWT) ─────────────────────────────────

export interface SplitShare {
  id: string;
  ticketId: string;
  name: string;
  email: string;
  phone: string | null;
  amountCents: number;
  paid: boolean;
  nudgeCount: number;
  transferStatus: string | null;
  claimPath: string | null;
}

export interface SplitState {
  sessionId: string;
  eventId: string;
  amountCents: number;
  quantity: number;
  currency: string;
  split: { venmoHandle: string | null; cashappTag: string | null; sendMode: 'now' | 'on_paid'; note: string | null } | null;
  tickets: { ticketId: string; tierName: string | null; mine: boolean; pendingTransfer: boolean; status: string }[];
  shares: SplitShare[];
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function toState(d: any): SplitState {
  return {
    sessionId: d.session_id,
    eventId: d.event_id,
    amountCents: Number(d.amount_cents ?? 0),
    quantity: Number(d.quantity ?? 0),
    currency: String(d.currency ?? 'usd'),
    split: d.split
      ? { venmoHandle: d.split.venmo_handle ?? null, cashappTag: d.split.cashapp_tag ?? null, sendMode: d.split.send_mode, note: d.split.note ?? null }
      : null,
    tickets: (d.tickets ?? []).map((t: any) => ({
      ticketId: t.ticket_id, tierName: t.tier_name ?? null, mine: !!t.mine, pendingTransfer: !!t.pending_transfer, status: t.status,
    })),
    shares: (d.shares ?? []).map((s: any) => ({
      id: s.id, ticketId: s.ticket_id, name: s.name, email: s.email, phone: s.phone ?? null,
      amountCents: Number(s.amount_cents ?? 0), paid: !!s.paid, nudgeCount: Number(s.nudge_count ?? 0),
      transferStatus: s.transfer_status ?? null, claimPath: s.claim_path ?? null,
    })),
  };
}

const clean = (m?: string) => (m ?? 'Something went wrong').replace(/^exos_split_[a-z_]+: |^exos_create_transfer: |^exos_bulk_create_transfers: /, '');

export async function getSplit(sessionId: string): Promise<SplitState> {
  const { data, error } = await supabase.rpc('exos_split_get', { p_session_id: sessionId });
  if (error) throw new Error(clean(error.message));
  return toState(data);
}

export async function saveSplit(input: {
  sessionId: string;
  shares: { ticketId: string; name: string; email: string; phone?: string; amountCents: number }[];
  venmo?: string;
  cashapp?: string;
  sendMode: 'now' | 'on_paid';
  note?: string;
}): Promise<SplitState> {
  const { data, error } = await supabase.rpc('exos_split_save', {
    p_session_id: input.sessionId,
    p_shares: input.shares.map((s) => ({
      ticket_id: s.ticketId, name: s.name.trim(), email: s.email.trim(), phone: s.phone?.trim() || null, amount_cents: s.amountCents,
    })),
    p_venmo: input.venmo?.trim() || null,
    p_cashapp: input.cashapp?.trim() || null,
    p_send_mode: input.sendMode,
    p_note: input.note?.trim() || null,
  });
  if (error) throw new Error(clean(error.message));
  return toState(data);
}

export async function markSharePaid(shareId: string, paid: boolean): Promise<SplitState> {
  const { data, error } = await supabase.rpc('exos_split_mark_paid', { p_share_id: shareId, p_paid: paid });
  if (error) throw new Error(clean(error.message));
  return toState(data);
}

export async function noteNudge(shareId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_split_nudged', { p_share_id: shareId });
  if (error) throw new Error(clean(error.message));
}
