// The door app's Sell tab (mig 20261107100000, docs/pos.md "Walk-up sales"):
// walk-up ticket sales for cash, as a comp or on a card reader (mig 20261107130000), the ticket handed over as a QR
// on this screen, on paper or by email, voids / refunds, and the cash drawer.
//
// Sales, voids, refunds, paid-outs and the print codes go through the exos-pos
// edge function (the signed-in member's JWT; every rule is in SQL). Opening
// and closing a drawer use the scaffold's own paths (an insert RLS allows for
// door staff, exos_pos_close_drawer). The pure money rules are in
// supabase/functions/_shared/pos/walkup.ts (src/lib/pos).

import { supabase } from './supabase';
import { printPdf, type PrintTicket } from '../../supabase/functions/_shared/print/tickets.ts';
import type { QuestionDef } from './checkoutQuestions';
import type { DoorRole } from './pos';

export interface WalkupTier {
  tier_id: string;
  name: string;
  price_cents: number;
  price_source: 'door' | 'step' | 'base';
  step_name: string | null;
  step_remaining: number | null;
  tax: { rate_percent: number; price_includes_tax: boolean } | null;
  unit_total_cents: number;
  /** null = no limit. */
  remaining: number | null;
}

export interface WalkupDrawer {
  id: string;
  device_id: string | null;
  mine: boolean;
  opened_at: string;
  open_float_cents: number;
  cash_cents: number;
}

/** A card reader the member may charge on (card at the door, mig 20261107130000). */
export interface WalkupReader {
  device_id: string;
  label: string;
  device_type: string | null;
}

export interface WalkupCardInfo {
  /** On (EXOS_POS_CARD) and the org has a reader this member may use. */
  connected: boolean;
  message: string;
  /** Present when the server's switch is on. */
  switched_on?: boolean;
  readers?: WalkupReader[];
  has_location?: boolean;
  can_manage?: boolean;
  /** Tap to Pay on iPhone: false until the native app exists (docs/pos.md). */
  tap_to_pay?: boolean;
}

export interface WalkupCatalog {
  event: { id: string; name: string; status: string; currency: string };
  role: DoorRole;
  can_comp: boolean;
  card: WalkupCardInfo;
  fee_base: string;
  tiers: WalkupTier[];
  questions: QuestionDef[];
  drawers: WalkupDrawer[];
}

export interface WalkupOrder {
  id: string;
  event_id: string;
  status: 'pending' | 'paid' | 'void' | 'refunded';
  payment_method: 'cash' | 'comp' | 'split' | 'card' | null;
  currency: string;
  total_cents: number;
  tax_cents: number;
  tenders: { cash: number; comp: number; card: number };
  tier_id: string | null;
  tier_name: string | null;
  quantity: number | null;
  comp_quantity: number;
  ticket_ids: string[];
  tickets_scanned: number;
  buyer_name: string | null;
  buyer_email: string | null;
  rung_by_me: boolean;
  created_at: string;
  can_void?: boolean;
  can_refund?: boolean;
  /** The seller or an owner / manager: show / print / email its tickets. */
  can_hand_over?: boolean;
  replay?: boolean;
  cash_returned_cents?: number;
  /** A card sale's attempt (never card data: the PaymentIntent id and Stripe's decline code). */
  card?: { status: string; mode: 'reader' | 'sdk'; payment_intent: string | null; decline_code: string | null } | null;
  card_refund?: { status: string | null; amount_cents: number; error?: string } | null;
}

/** card_status / card_cancel: where a card sale is. */
export interface CardProgress {
  state: 'waiting' | 'succeeded' | 'declined' | 'canceled' | 'refunded';
  order?: WalkupOrder | null;
  decline_code?: string | null;
}

/** The function's answer: { data } on success, { error, message } otherwise. */
export class PosError extends Error {
  constructor(message: string, public code: string | null, public status: number) {
    super(message);
  }
}

// What the door sees for each refusal (the SQL hint / the function's code).
const FRIENDLY: Record<string, string> = {
  'card-not-connected': "Card at the door isn't connected yet: take cash, or comp it.",
  card_not_connected: "Card at the door isn't connected yet: take cash, or comp it.",
  'no-drawer': 'Open a cash drawer first (or pick an open one).',
  'sold-out': 'Sold out.',
  'comp-role': 'Comps need an owner or manager.',
  scanned: 'A ticket of this sale was scanned: an owner or manager can refund it.',
  'too-late': 'Too late to void (12 hours): an owner or manager can refund it.',
  override: 'A ticket was scanned: refunding needs the override.',
  expired: 'The places were given back: start the sale again.',
  'drawer-short': "The drawer doesn't have that much cash.",
  'not-your-drawer': "That drawer is someone else's: use your own, or ask a manager.",
  'handed-over': 'These tickets were already handed over, claimed or scanned: an owner or manager can resend them.',
  'no-reader': "Pick one of this organization's card readers.",
  'no-location': "Card at the door isn't set up for this organization yet.",
  'card-setup': "This organizer hasn't finished payment setup: take cash.",
  'card-zero': 'Nothing to charge: sell it as cash.',
  'card-refund-in-app': 'A card sale is refunded to the card from the door app.',
  'not-card': "This sale isn't a card sale.",
  card_service: "The card service didn't answer: try again.",
};

/** A refusal as the door shows it. */
export function posErrorText(e: unknown): string {
  if (e instanceof PosError) return (e.code && FRIENDLY[e.code]) || e.message;
  return e instanceof Error ? e.message : 'Something went wrong.';
}

async function call<T>(body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke('exos-pos', { body });
  if (error) {
    let payload: { error?: string; message?: string } | null = null;
    const ctx = (error as { context?: Response }).context;
    try {
      payload = await ctx?.json();
    } catch {
      /* not JSON */
    }
    throw new PosError(payload?.message || payload?.error || (error as Error).message || 'Request failed',
      payload?.error ?? null, ctx?.status ?? 0);
  }
  return (data as { data: T }).data;
}

/** A fresh order key: one per sale, reused on a retry so a double tap is one sale. */
export function newOrderKey(): string {
  return crypto.randomUUID();
}

export const getWalkupCatalog = (eventId: string) => call<WalkupCatalog>({ action: 'walkup_catalog', event_id: eventId });
export const getRecentSales = (eventId: string, limit = 20) => call<WalkupOrder[]>({ action: 'recent_sales', event_id: eventId, limit });

export function sellWalkup(input: {
  eventId: string; tierId: string; quantity: number; orderKey: string; compQuantity?: number;
  payment: 'cash' | 'comp'; drawerId?: string | null; buyerName?: string; buyerEmail?: string;
  answers?: unknown; compReason?: string;
}): Promise<WalkupOrder> {
  return call<WalkupOrder>({
    action: 'mint_walkup', event_id: input.eventId, tier_id: input.tierId, quantity: input.quantity,
    order_key: input.orderKey, comp_quantity: input.compQuantity ?? 0, payment: input.payment,
    drawer_id: input.drawerId || undefined, buyer_name: input.buyerName?.trim() || undefined,
    buyer_email: input.buyerEmail?.trim() || undefined, answers: input.answers, comp_reason: input.compReason?.trim() || undefined,
  });
}

// Card at the door (mig 20261107130000). The reader handles the card; these
// calls carry only ids. No card field, ever (docs/pci.md).

/** Start a card sale: the places are held for 5 minutes while the guest pays. */
export function beginCardSale(input: {
  eventId: string; tierId: string; quantity: number; orderKey: string; buyerName?: string; buyerEmail?: string; answers?: unknown;
}): Promise<WalkupOrder> {
  return call<WalkupOrder>({
    action: 'mint_walkup', payment: 'card', event_id: input.eventId, tier_id: input.tierId, quantity: input.quantity,
    order_key: input.orderKey, comp_quantity: 0, buyer_name: input.buyerName?.trim() || undefined,
    buyer_email: input.buyerEmail?.trim() || undefined, answers: input.answers,
  });
}
/** Send the pending sale's charge to a smart reader (server-driven). */
export const chargeOnReader = (orderId: string, readerDeviceId: string) =>
  call<{ order_id: string; card: { status: string; payment_intent: string | null } }>(
    { action: 'card_payment', order_id: orderId, mode: 'reader', reader_device_id: readerDeviceId });
/** Where the card sale is (captures it once the reader authorized). */
export const cardStatus = (orderId: string) => call<CardProgress>({ action: 'card_status', order_id: orderId });
/** Stop the reader and cancel the pending card sale (places back). */
export const cancelCardSale = (orderId: string, reason?: string) =>
  call<CardProgress>({ action: 'card_cancel', order_id: orderId, reason: reason || undefined });
/** Owner / manager: the venue's address for Stripe Terminal (once per organization). */
export const setupCardLocation = (eventId: string, address: Record<string, string>, displayName?: string) =>
  call<{ location: unknown; created: boolean }>({ action: 'terminal_location', event_id: eventId, address, display_name: displayName || undefined });
/** Owner / manager: register a smart reader by the code it shows. */
export const registerReader = (eventId: string, registrationCode: string, label: string) =>
  call<{ device_id: string; label: string }>({ action: 'register_reader', event_id: eventId, registration_code: registrationCode, label });

export const voidSale = (orderId: string, reason: string, drawerId?: string | null) =>
  call<WalkupOrder>({ action: 'void_order', order_id: orderId, reason, drawer_id: drawerId || undefined });
export const refundSale = (orderId: string, reason: string, override: boolean, drawerId?: string | null) =>
  call<WalkupOrder>({ action: 'refund_order', order_id: orderId, reason, override, drawer_id: drawerId || undefined });
export const paidOut = (drawerId: string, amountCents: number, reason: string, key: string) =>
  call<{ id: string; amount_cents: number; drawer_cash_cents: number }>({ action: 'paid_out', drawer_id: drawerId, amount_cents: amountCents, reason, key });
export const emailSale = (orderId: string, email: string) => call<WalkupOrder>({ action: 'email_order', order_id: orderId, email });

/** One-time print codes for a sale's tickets (shown as a QR, or printed). */
export async function saleCodes(orderId: string): Promise<{ tickets: PrintTicket[]; skipped: Array<{ ticket_id: string; reason: string }> }> {
  const d = await call<{ tickets?: PrintTicket[]; skipped?: Array<{ ticket_id: string; reason: string }> }>({ action: 'order_codes', order_id: orderId });
  return { tickets: Array.isArray(d?.tickets) ? d.tickets : [], skipped: Array.isArray(d?.skipped) ? d.skipped : [] };
}

/** The same codes as a 4 x 8 in PDF (any ticket printer prints it). */
export function ticketsPdf(tickets: PrintTicket[]): Uint8Array {
  return printPdf(tickets, 'Door tickets');
}

/** Open a drawer at this event with a float (door staff; RLS). */
export async function openDrawer(eventId: string, floatCents: number): Promise<string> {
  const { data, error } = await supabase.from('exos_pos_drawer_sessions')
    .insert({ event_id: eventId, open_float_cents: floatCents }).select('id').single();
  if (error) throw new PosError(error.message, null, 0);
  return (data as { id: string }).id;
}

/** Count and close a drawer: { expected_cents, counted_cents, variance_cents, paid_out_cents }. */
export async function closeDrawer(drawerId: string, countedCents: number, note?: string) {
  const { data, error } = await supabase.rpc('exos_pos_close_drawer', {
    p_session_id: drawerId, p_counted_cents: countedCents, p_counts: null, p_note: note || null,
  });
  if (error) throw new PosError(error.message, null, 0);
  return data as { expected_cents: number; counted_cents: number; variance_cents: number; paid_out_cents?: number };
}
