// Group buy v2, "pay separately" (mig 20261108120000; KANBAN "Group buy /
// split pay"). The host starts a group of N seats of one ticket type: Exos
// holds them for 30 minutes and gives the host one link per seat. Each friend
// opens their link and pays for that seat in a normal checkout (the ticket is
// theirs, its own order). Before the deadline the host can cover every unpaid
// seat in one checkout; after it, unpaid seats go back on sale.
//
// v1 ("split with friends", lib/split.ts) is still there: the host pays for
// everything and friends pay the host back.
//
// Group pay 2 (mig 20261110110000): timed types (the whole group takes one
// slot), price-step types (every seat locks the start's price; friends and
// the cover pay it) and the host's own names for seats (labels: the host page
// only, never the friend's seat page).

import { supabase } from './supabase';
import { smsUrl } from './split';
import { tierAllInPrice } from './pricing';

/** The most seats a group can have for an event (exos-checkout caps an order at 10). */
export function maxGroupSize(maxPerOrder?: number | null): number {
  const m = Number(maxPerOrder);
  return Number.isInteger(m) && m > 0 ? Math.min(10, m) : 10;
}

/** A group is 2 or more seats, at most maxGroupSize. */
export function canStartGroup(quantity: number, maxPerOrder?: number | null): boolean {
  return Number.isInteger(quantity) && quantity >= 2 && quantity <= maxGroupSize(maxPerOrder);
}

/** Whole seconds left until the deadline, by the server's clock (never negative). */
export function secondsLeft(deadlineIso: string, serverNowIso: string | null, fetchedAtMs: number, nowMs: number = Date.now()): number {
  const deadline = Date.parse(deadlineIso);
  if (!Number.isFinite(deadline)) return 0;
  // The server's "now" at fetch time, moved on by the local clock since then:
  // a phone whose clock is off still counts down the server's 30 minutes.
  const serverNow = serverNowIso && Number.isFinite(Date.parse(serverNowIso)) ? Date.parse(serverNowIso) : fetchedAtMs;
  const elapsed = Math.max(0, nowMs - fetchedAtMs);
  return Math.max(0, Math.floor((deadline - (serverNow + elapsed)) / 1000));
}

/** 29:05, 0:09. */
export function formatCountdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

export type SeatState = 'waiting' | 'paying' | 'covering' | 'paid' | 'covered' | 'released';

/** How a seat reads, to the host and on the friend's page. */
export function seatLabel(state: SeatState): string {
  switch (state) {
    case 'paid': return 'Paid';
    case 'covered': return 'You covered it';
    case 'paying': return 'Paying now';
    case 'covering': return 'In your checkout';
    case 'released': return 'Released';
    default: return 'Waiting';
  }
}

/** The text a host sends a friend with their seat link. */
export function seatMessage(opts: { eventTitle: string; seatNo: number; url: string; minutesLeft: number; priceLabel?: string | null }): string {
  const mins = Math.max(1, Math.round(opts.minutesLeft));
  return [
    `Your seat for ${opts.eventTitle} (seat ${opts.seatNo})${opts.priceLabel ? `: ${opts.priceLabel}` : ''}.`,
    `Pay for it here in the next ${mins} min, or it goes back on sale:`,
    opts.url,
  ].join('\n');
}

export function seatSmsUrl(body: string): string {
  return smsUrl(null, body);
}

/** The most characters a seat label holds (exos_group_buy_seats_label_chk). */
export const SEAT_LABEL_MAX = 40;

/** A host's seat label as stored: trimmed, one space between words, no
 *  control characters, at most 40 characters; empty means no label. */
export function normalizeSeatLabel(raw: string | null | undefined): string | null {
  // eslint-disable-next-line no-control-regex
  const s = String(raw ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!s) return null;
  return Array.from(s).slice(0, SEAT_LABEL_MAX).join('').trim() || null;
}

/** What a group seat costs the buyer, all-in: the price the group locked at
 *  the start (a price-step type), else the type's current price. */
export function groupSeatPrice(tier: Parameters<typeof tierAllInPrice>[0], lockedCents: number | null | undefined, current: number): number {
  if (typeof lockedCents === 'number' && Number.isInteger(lockedCents) && lockedCents > 0) {
    return tierAllInPrice(tier, lockedCents / 100);
  }
  return current;
}

// ── API ─────────────────────────────────────────────────────────────────────

export interface GroupSeat {
  id: string;
  seatNo: number;
  /** The host's name for the seat (host page only). */
  label: string | null;
  state: SeatState;
  path: string;
  paidAt: string | null;
  orderStatus: string | null;
}

export interface GroupBuy {
  id: string;
  eventId: string;
  tierId: string;
  quantity: number;
  deadline: string;
  status: 'open' | 'closed' | 'cancelled';
  serverNow: string | null;
  fetchedAt: number;
  /** Timed entry: the slot every seat is on ('YYYYMMDDTHHMM'). */
  slotId: string | null;
  /** Price steps: the face price every seat locked, in cents. */
  unitPriceCents: number | null;
  canCover: boolean;
  counts: { paid: number; paying: number; waiting: number; released: number };
  seats: GroupSeat[];
}

/** Seats "cover the rest" would pay for: everything not paid or released. */
export function coverableSeats(g: Pick<GroupBuy, 'seats'>): GroupSeat[] {
  return g.seats.filter((s) => s.state === 'waiting' || s.state === 'paying' || s.state === 'covering');
}

/** Friends on a checkout page right now: covering takes their seats too. */
export function friendsPayingNow(g: Pick<GroupBuy, 'seats'>): number {
  return g.seats.filter((s) => s.state === 'paying').length;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function toGroup(d: any, fetchedAt: number = Date.now()): GroupBuy {
  const c = d?.counts ?? {};
  return {
    id: String(d.id),
    eventId: String(d.event_id),
    tierId: String(d.tier_id),
    quantity: Number(d.quantity ?? 0),
    deadline: String(d.deadline),
    status: d.status === 'cancelled' ? 'cancelled' : d.status === 'closed' ? 'closed' : 'open',
    serverNow: d.server_now ?? null,
    fetchedAt,
    slotId: typeof d.slot_id === 'string' ? d.slot_id : null,
    unitPriceCents: Number.isInteger(d.unit_price_cents) ? Number(d.unit_price_cents) : null,
    canCover: !!d.can_cover,
    counts: { paid: Number(c.paid ?? 0), paying: Number(c.paying ?? 0), waiting: Number(c.waiting ?? 0), released: Number(c.released ?? 0) },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    seats: (d.seats ?? []).map((s: any) => ({
      id: String(s.id), seatNo: Number(s.seat_no), label: typeof s.label === 'string' && s.label ? s.label : null,
      state: (s.state ?? 'waiting') as SeatState, path: String(s.path ?? ''),
      paidAt: s.paid_at ?? null, orderStatus: s.order_status ?? null,
    })),
  };
}

export interface SeatView {
  seatNo: number;
  seats: number;
  state: SeatState;
  mine: boolean;
  isHost: boolean;
  groupId: string | null;
  deadline: string;
  serverNow: string | null;
  fetchedAt: number;
  groupStatus: 'open' | 'closed' | 'cancelled';
  paid: number;
  open: number;
  eventId: string;
  tierId: string;
  slotId: string | null;
  unitPriceCents: number | null;
  event: { name: string; startsAt: string | null; venueName: string | null; imageUrl: string | null; currency: string } | null;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function toSeatView(d: any, fetchedAt: number = Date.now()): SeatView | null {
  if (!d || typeof d !== 'object') return null;
  return {
    seatNo: Number(d.seat_no),
    seats: Number(d.seats),
    state: (d.state ?? 'released') as SeatState,
    mine: !!d.mine,
    isHost: !!d.is_host,
    groupId: d.group_id ?? null,
    deadline: String(d.deadline),
    serverNow: d.server_now ?? null,
    fetchedAt,
    groupStatus: d.group_status === 'cancelled' ? 'cancelled' : d.group_status === 'closed' ? 'closed' : 'open',
    paid: Number(d.paid ?? 0),
    open: Number(d.open ?? 0),
    // Null once the event is unpublished (mig 20261109110000): '' so the page
    // looks nothing up and the seat can't be paid.
    eventId: d.event_id == null ? '' : String(d.event_id),
    tierId: d.tier_id == null ? '' : String(d.tier_id),
    slotId: typeof d.slot_id === 'string' ? d.slot_id : null,
    unitPriceCents: Number.isInteger(d.unit_price_cents) ? Number(d.unit_price_cents) : null,
    event: d.event ? {
      name: String(d.event.name ?? ''), startsAt: d.event.starts_at ?? null, venueName: d.event.venue_name ?? null,
      imageUrl: d.event.image_url ?? null, currency: String(d.event.currency || 'USD'),
    } : null,
  };
}

/** Can this friend pay for this seat now? */
export function seatPayable(v: Pick<SeatView, 'state' | 'mine' | 'groupStatus'>, secondsRemaining: number): boolean {
  if (v.groupStatus !== 'open' || secondsRemaining <= 60) return false;
  return v.state === 'waiting' || (v.state === 'paying' && v.mine);
}

export const SEAT_TOKEN_RE = /^[0-9a-f]{32}$/;

const clean = (m?: string) => (m ?? 'Something went wrong').replace(/^exos_group_[a-z_]+: |^exos_create_hold: /, '');

/** Start a group; a timed type needs the slot every seat will take. */
export async function startGroup(eventId: string, tierId: string, quantity: number, slotId?: string | null): Promise<GroupBuy> {
  const { data, error } = await supabase.rpc('exos_group_buy_start', {
    p_event_id: eventId, p_tier_id: tierId, p_quantity: quantity,
    ...(slotId ? { p_slot_id: slotId } : {}),
  });
  if (error) throw new Error(clean(error.message));
  return toGroup(data);
}

/** Name a seat (the host, or a platform admin; RLS refuses anyone else).
 *  Returns the label as stored. */
export async function setSeatLabel(seatId: string, raw: string): Promise<string | null> {
  const label = normalizeSeatLabel(raw);
  const { data, error } = await supabase.from('exos_group_buy_seats').update({ label }).eq('id', seatId).select('id, label');
  if (error) throw new Error(clean(error.message));
  if (!Array.isArray(data) || data.length === 0) throw new Error("Couldn't save the name: only the host can name seats.");
  return label;
}

export async function getGroup(groupId: string): Promise<GroupBuy> {
  const { data, error } = await supabase.rpc('exos_group_buy_get', { p_group_id: groupId });
  if (error) throw new Error(clean(error.message));
  return toGroup(data);
}

export async function cancelGroup(groupId: string): Promise<GroupBuy> {
  const { data, error } = await supabase.rpc('exos_group_buy_cancel', { p_group_id: groupId });
  if (error) throw new Error(clean(error.message));
  return toGroup(data);
}

export interface MyGroup { id: string; eventId: string; quantity: number; deadline: string; status: string; paid: number }

export async function myGroups(eventId?: string): Promise<MyGroup[]> {
  const { data, error } = await supabase.rpc('exos_group_buy_mine', { p_event_id: eventId ?? null });
  if (error) throw new Error(clean(error.message));
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return ((data ?? []) as any[]).map((g) => ({
    id: String(g.id), eventId: String(g.event_id), quantity: Number(g.quantity), deadline: String(g.deadline),
    status: String(g.status), paid: Number(g.paid ?? 0),
  }));
}

/** One seat's page: anyone with the link. null for an unknown link. */
export async function viewSeat(token: string): Promise<SeatView | null> {
  if (!SEAT_TOKEN_RE.test(token)) return null;
  const { data, error } = await supabase.rpc('exos_group_seat_view', { p_token: token });
  if (error) throw new Error(clean(error.message));
  return toSeatView(data);
}
