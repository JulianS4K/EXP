// Venue POS: card at the door through Stripe Terminal (mig 20261107130000,
// docs/pos.md "Card at the door"). Shared by exos-pos (the door) and
// stripe-webhook (the fallback), and tested in vitest with fakes: nothing
// here imports Stripe or Supabase, both come in through the small structural
// interfaces below.
//
// The charge model is exos-checkout's: a DESTINATION charge on the platform
// account (transfer_data.destination = the org's connected account) with an
// application fee = the Exos fee + Stripe's card fee, which the platform pays
// under destination charges (_shared/platformFee.ts checkoutFeeSplit). The
// card fee is estimated at Stripe Terminal's in-person rate (2.7% + 5c,
// EXOS_STRIPE_TERMINAL_FEE_BPS / _FIXED_CENTS override). The Exos rate is the
// event's (exos_event_fee_bps: 0 in the org's free months and on the free
// tier); under either pos_walkup_fee_base value a card walk-up pays it.
//
// card_present PaymentIntents use MANUAL capture: the reader authorizes, then
// Exos captures only after checking, under the order lock, that the places
// are still held (_exos_pos_card_capture_prepare). An authorization Exos
// doesn't capture is cancelled and takes no money.
//
// NO CARD DATA here or anywhere in Exos: the reader handles the card; Exos
// sees the PaymentIntent id, its status and Stripe's decline code.

import { checkoutFeeSplit, type CardFee, type CheckoutFeeSplit } from '../platformFee.ts';
import { STRIPE_TERMINAL_FEE } from './settlement.ts';
import { refundFlags, refundFlagsForMode } from '../payouts/commissionMethods.ts';
import type { CollectRequest, CollectResult, PaymentTerminal, RefundResult } from './terminal.ts';

// ---------------------------------------------------------------------------
// The switch.
// ---------------------------------------------------------------------------

export interface CardSwitch {
  on: boolean;
  /** The Stripe key is a live one (sk_live_ / rk_live_). */
  live: boolean;
  /** Why it's off, for the 501 / 503 answer. */
  reason?: 'off' | 'no-key' | 'live-not-allowed';
}

/**
 * Card at the door is on when EXOS_POS_CARD=on and a Stripe key is set. A
 * live key also needs EXOS_POS_CARD_LIVE=on (going live with card at the
 * door is its own operator step: Terminal enabled, locations, readers).
 */
export function cardSwitch(env: (k: string) => string | undefined): CardSwitch {
  if ((env('EXOS_POS_CARD') ?? '').trim().toLowerCase() !== 'on') return { on: false, live: false, reason: 'off' };
  const key = (env('STRIPE_SECRET_KEY') ?? '').trim();
  if (!key) return { on: false, live: false, reason: 'no-key' };
  const live = /^(sk|rk)_live_/.test(key);
  if (live && (env('EXOS_POS_CARD_LIVE') ?? '').trim().toLowerCase() !== 'on') {
    return { on: false, live, reason: 'live-not-allowed' };
  }
  return { on: true, live };
}

/** Stripe Terminal's in-person rate, or the env override. */
export function terminalCardFee(env: (k: string) => string | undefined): CardFee {
  const n = (k: string, d: number) => {
    const v = Number(env(k));
    return Number.isFinite(v) && v >= 0 ? Math.round(v) : d;
  };
  return {
    bps: n('EXOS_STRIPE_TERMINAL_FEE_BPS', STRIPE_TERMINAL_FEE.bps),
    fixedCents: n('EXOS_STRIPE_TERMINAL_FEE_FIXED_CENTS', STRIPE_TERMINAL_FEE.fixedCents),
  };
}

// ---------------------------------------------------------------------------
// The PaymentIntent.
// ---------------------------------------------------------------------------

/** What _exos_pos_card_begin answers (the amount is the order's, never the client's). */
export interface CardPlan {
  done: boolean;
  order_id: string;
  event_id: string;
  org_id: string;
  amount_cents: number;
  currency: string;
  fee_bps: number;
  fee_base: string;
  /** The org's connected account (transfer_data.destination). Never sent to the door app. */
  destination: string;
  location_id: string;
  reader_id: string | null;
  mode: 'reader' | 'sdk';
  payment_intent_id: string | null;
  status: string;
  description: string;
}

export const POS_METADATA_KEY = 'exos_pos_order';

export function piIdempotencyKey(orderId: string): string {
  return `exos_pos_pi_${orderId}`;
}
export function captureIdempotencyKey(pi: string): string {
  return `exos_pos_capture_${pi}`;
}
export function refundIdempotencyKey(orderId: string): string {
  return `exos_pos_refund_${orderId}`;
}
export function autoRefundIdempotencyKey(orderId: string): string {
  return `exos_pos_autorefund_${orderId}`;
}

/** The fee split for one card sale: exactly what exos-checkout would record for the same amount and rates. */
export function cardFeeSplit(amountCents: number, feeBps: number, cardFee: CardFee = STRIPE_TERMINAL_FEE): CheckoutFeeSplit {
  return checkoutFeeSplit(amountCents, { bps: feeBps, card: cardFee });
}

export interface PaymentIntentCreateParams {
  amount: number;
  currency: string;
  payment_method_types: string[];
  capture_method: 'manual';
  application_fee_amount: number;
  transfer_data: { destination: string };
  on_behalf_of?: string;
  description: string;
  metadata: Record<string, string>;
}

/**
 * The card_present PaymentIntent for a walk-up order: the order's amount
 * and currency, manual capture, the destination charge and application fee
 * of an online sale, and the order in the metadata (the webhook fallback
 * finds the sale by it). `onBehalfOf` makes the connected account the
 * settlement merchant (its name on the receipt); off by default, as online.
 */
export function cardPaymentIntentParams(
  plan: Pick<CardPlan, 'order_id' | 'event_id' | 'org_id' | 'amount_cents' | 'currency' | 'fee_bps' | 'destination' | 'description'>,
  opts: { cardFee?: CardFee; onBehalfOf?: boolean } = {},
): { params: PaymentIntentCreateParams; idempotencyKey: string; fee: CheckoutFeeSplit } {
  const amount = Math.round(plan.amount_cents);
  if (!Number.isInteger(amount) || amount <= 0) throw new Error('card amount must be positive whole cents');
  if (!/^acct_[A-Za-z0-9]+$/.test(plan.destination)) throw new Error('no connected account');
  const fee = cardFeeSplit(amount, plan.fee_bps, opts.cardFee ?? STRIPE_TERMINAL_FEE);
  return {
    params: {
      amount,
      currency: plan.currency.toLowerCase(),
      payment_method_types: ['card_present'],
      capture_method: 'manual',
      application_fee_amount: fee.applicationFeeCents,
      transfer_data: { destination: plan.destination },
      ...(opts.onBehalfOf ? { on_behalf_of: plan.destination } : {}),
      description: plan.description.slice(0, 200),
      metadata: {
        [POS_METADATA_KEY]: plan.order_id,
        exos_event_id: plan.event_id,
        exos_org_id: plan.org_id,
        exos_kind: 'pos_walkup',
      },
    },
    idempotencyKey: piIdempotencyKey(plan.order_id),
    fee,
  };
}

/** A Stripe Terminal Location's address, checked before Stripe sees it. */
export interface TerminalAddress {
  line1: string;
  line2?: string;
  city: string;
  state?: string;
  postal_code: string;
  country: string;
}

/** The address an owner typed, cleaned, or the reason it can't be used. */
export function terminalAddress(raw: unknown): { address: TerminalAddress } | { error: string } {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'the address is required' };
  const r = raw as Record<string, unknown>;
  const s = (k: string, max: number) => (typeof r[k] === 'string' ? (r[k] as string).trim().slice(0, max) : '');
  const country = s('country', 2).toUpperCase();
  const a: TerminalAddress = { line1: s('line1', 200), city: s('city', 100), postal_code: s('postal_code', 20), country };
  const line2 = s('line2', 200);
  const state = s('state', 50);
  if (line2) a.line2 = line2;
  if (state) a.state = state;
  if (!a.line1 || !a.city || !a.postal_code) return { error: 'the address needs a street, a city and a postal code' };
  if (!/^[A-Z]{2}$/.test(country)) return { error: 'the country is a two-letter code, e.g. US' };
  if ((country === 'US' || country === 'CA' || country === 'AU') && !a.state) return { error: 'the address needs a state or province' };
  return { address: a };
}

/** A registration code a reader shows (three words, or Stripe's simulated-wpe in test mode). */
export function isRegistrationCode(v: unknown): v is string {
  return typeof v === 'string' && /^[A-Za-z0-9-]{3,64}$/.test(v.trim());
}

// ---------------------------------------------------------------------------
// The state machine.
// ---------------------------------------------------------------------------

export interface IntentLike {
  id: string;
  status: string;
  amount?: number;
  amount_received?: number;
  amount_capturable?: number;
  client_secret?: string | null;
  metadata?: Record<string, string> | null;
  last_payment_error?: { code?: string | null; decline_code?: string | null; message?: string | null } | null;
}

export interface ReaderActionLike {
  type?: string;
  status?: string;
  failure_code?: string | null;
  failure_message?: string | null;
  process_payment_intent?: { payment_intent?: string | { id: string } | null } | null;
}

export type CardStep =
  | { step: 'capture' }
  | { step: 'complete' }
  | { step: 'declined'; code: string | null }
  | { step: 'canceled' }
  | { step: 'waiting' };

/**
 * What to do with a PaymentIntent now:
 *   requires_capture   the reader authorized it: capture (if the sale still stands)
 *   succeeded          captured (by us, or another path): complete the sale
 *   canceled           nothing was taken: cancel the sale
 *   requires_payment_method with an error, or the reader's action failed on
 *                      this PaymentIntent: declined
 *   anything else      still waiting for the card
 */
export function cardStep(pi: IntentLike, action?: ReaderActionLike | null): CardStep {
  switch (pi.status) {
    case 'requires_capture': return { step: 'capture' };
    case 'succeeded': return { step: 'complete' };
    case 'canceled': return { step: 'canceled' };
  }
  if (pi.status === 'requires_payment_method' && pi.last_payment_error) {
    return { step: 'declined', code: pi.last_payment_error.decline_code ?? pi.last_payment_error.code ?? null };
  }
  const actPi = action?.process_payment_intent?.payment_intent;
  const actPiId = typeof actPi === 'string' ? actPi : actPi?.id;
  if (action?.status === 'failed' && actPiId === pi.id) return { step: 'declined', code: action.failure_code ?? null };
  return { step: 'waiting' };
}

/** A decline code safe to store and show (Stripe's codes are lowercase words). */
export function cleanDeclineCode(code: string | null | undefined): string | null {
  const c = String(code ?? '').toLowerCase();
  return /^[a-z0-9_]{1,64}$/.test(c) ? c : null;
}

// ---------------------------------------------------------------------------
// The adapters: Stripe and the database, as small interfaces.
// ---------------------------------------------------------------------------

export interface StripeOpts { idempotencyKey?: string }
// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;

export interface TerminalStripe {
  createPaymentIntent(params: PaymentIntentCreateParams, opts: StripeOpts): Promise<IntentLike>;
  retrievePaymentIntent(id: string): Promise<IntentLike>;
  capturePaymentIntent(id: string, opts: StripeOpts): Promise<IntentLike>;
  cancelPaymentIntent(id: string): Promise<IntentLike>;
  processPaymentIntent(readerId: string, paymentIntentId: string): Promise<Obj>;
  cancelReaderAction(readerId: string): Promise<Obj>;
  retrieveReader(readerId: string): Promise<{ id: string; action?: ReaderActionLike | null }>;
  createRefund(params: Obj, opts: StripeOpts): Promise<{ id: string; status?: string | null; failure_reason?: string | null }>;
}

export interface DbError { code?: string; message?: string; hint?: string | null }
export interface CardDb {
  rpc(fn: string, args: Record<string, unknown>): Promise<{ data: unknown; error: DbError | null }>;
}

/** A database refusal, carried to the HTTP answer. */
export class CardDbError extends Error {
  constructor(public readonly db: DbError) {
    super(db.message ?? 'request failed');
    this.name = 'CardDbError';
  }
}

async function call<T>(db: CardDb, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new CardDbError(error);
  return data as T;
}

function stripeType(e: unknown): string {
  return String((e as { type?: string } | null)?.type ?? '');
}
function stripeCode(e: unknown): string {
  return String((e as { code?: string } | null)?.code ?? '');
}

// ---------------------------------------------------------------------------
// StripeTerminal: the PaymentTerminal over Stripe (server-driven readers;
// with no reader connected it leaves the payment to an SDK).
// ---------------------------------------------------------------------------

export interface ConnectCharge {
  orderId: string;
  eventId: string;
  orgId: string;
  destination: string;
  feeBps: number;
  description: string;
  cardFee?: CardFee;
  onBehalfOf?: boolean;
  keepPlatformFee?: boolean;
}

export class StripeTerminal implements PaymentTerminal {
  readonly kind = 'stripe-terminal' as const;
  private readerId: string | null = null;
  private lastIntent: string | null = null;
  /** The fee split of the last PaymentIntent collect() made. */
  lastFee: CheckoutFeeSplit | null = null;

  constructor(
    private readonly stripe: TerminalStripe,
    private readonly charge: ConnectCharge,
    /** Called with the new PaymentIntent before the reader sees it; false = the sale ended, cancel it. */
    private readonly onCreated?: (pi: IntentLike, fee: CheckoutFeeSplit) => Promise<boolean>,
  ) {}

  connect(readerRef: string): Promise<void> {
    if (!/^tmr_[A-Za-z0-9]+$/.test(readerRef)) return Promise.reject(new Error('not a Stripe Terminal reader id'));
    this.readerId = readerRef;
    return Promise.resolve();
  }

  async collect(req: CollectRequest): Promise<CollectResult> {
    if ((req.tipCents ?? 0) !== 0) throw new Error('tips on the reader are not built (docs/pos.md decision 3)');
    if (req.orderId !== this.charge.orderId) throw new Error('collect is for this order only');
    const { params, fee } = cardPaymentIntentParams({
      order_id: this.charge.orderId, event_id: this.charge.eventId, org_id: this.charge.orgId,
      amount_cents: req.amountCents, currency: req.currency, fee_bps: this.charge.feeBps,
      destination: this.charge.destination, description: this.charge.description,
    }, { cardFee: this.charge.cardFee, onBehalfOf: this.charge.onBehalfOf });
    const pi = await this.stripe.createPaymentIntent(params, { idempotencyKey: req.idempotencyKey });
    this.lastIntent = pi.id;
    this.lastFee = fee;
    if (this.onCreated && !(await this.onCreated(pi, fee))) {
      await this.stripe.cancelPaymentIntent(pi.id).catch(() => undefined);
      return { status: 'canceled', amountCents: 0, tipCents: 0 };
    }
    return await this.present(pi);
  }

  /** Send an existing PaymentIntent to the reader (a retry), or hand its secret to the SDK. */
  async present(pi: IntentLike): Promise<CollectResult> {
    this.lastIntent = pi.id;
    if (this.readerId) {
      await this.stripe.processPaymentIntent(this.readerId, pi.id);
      return { status: 'processing', terminalRef: pi.id, amountCents: pi.amount ?? 0, tipCents: 0 };
    }
    return { status: 'processing', terminalRef: pi.id, amountCents: pi.amount ?? 0, tipCents: 0, clientSecret: pi.client_secret ?? undefined };
  }

  async refund(terminalRef: string, amountCents: number): Promise<RefundResult> {
    try {
      const r = await this.stripe.createRefund({
        payment_intent: terminalRef, amount: amountCents, reason: 'requested_by_customer',
        ...refundFlagsForMode('standard', this.charge.keepPlatformFee === true),
        metadata: { [POS_METADATA_KEY]: this.charge.orderId },
      }, { idempotencyKey: refundIdempotencyKey(this.charge.orderId) });
      return { status: r.status === 'failed' || r.status === 'canceled' ? 'failed' : 'succeeded', refundRef: r.id, amountCents };
    } catch {
      return { status: 'failed', amountCents: 0 };
    }
  }

  async cancel(): Promise<void> {
    if (this.readerId) await this.stripe.cancelReaderAction(this.readerId).catch(() => undefined);
    if (this.lastIntent) await this.stripe.cancelPaymentIntent(this.lastIntent).catch(() => undefined);
  }
}

// ---------------------------------------------------------------------------
// The flows (exos-pos and stripe-webhook).
// ---------------------------------------------------------------------------

export interface CardFlowOpts {
  cardFee?: CardFee;
  onBehalfOf?: boolean;
  keepPlatformFee?: boolean;
}

export interface StartResult {
  status: 'processing' | 'canceled' | 'done';
  payment_intent: string | null;
  /** SDK mode only. */
  client_secret?: string;
}

/**
 * Charge a pending card sale: create the PaymentIntent (once per order: the
 * idempotency key, and the stored id on a retry), record it, then send it to
 * the reader or hand the SDK its client secret. `plan` is _exos_pos_card_begin's.
 */
export async function startCardPayment(db: CardDb, stripe: TerminalStripe, plan: CardPlan, opts: CardFlowOpts = {}): Promise<StartResult> {
  if (plan.done) return { status: 'done', payment_intent: plan.payment_intent_id };
  const term = new StripeTerminal(stripe, {
    orderId: plan.order_id, eventId: plan.event_id, orgId: plan.org_id, destination: plan.destination,
    feeBps: plan.fee_bps, description: plan.description, cardFee: opts.cardFee, onBehalfOf: opts.onBehalfOf,
    keepPlatformFee: opts.keepPlatformFee,
  }, async (pi, fee) => {
    if (pi.amount !== undefined && pi.amount !== plan.amount_cents) return false;
    const r = await call<{ cancel: boolean }>(db, '_exos_pos_card_attach', {
      p_order: plan.order_id, p_pi: pi.id, p_amount: plan.amount_cents, p_currency: plan.currency,
      p_app_fee: fee.applicationFeeCents, p_exos_fee: fee.exosFeeCents, p_card_fee: fee.cardFeeEstCents, p_fee_bps: fee.feeBps,
    });
    return r?.cancel !== true;
  });
  if (plan.mode === 'reader') {
    if (!plan.reader_id) throw new Error('no reader');
    await term.connect(plan.reader_id);
  }
  let res: CollectResult;
  if (plan.payment_intent_id) {
    // A retry: the same PaymentIntent, on this reader (or for the SDK).
    const pi = await stripe.retrievePaymentIntent(plan.payment_intent_id);
    if (pi.status === 'requires_capture' || pi.status === 'succeeded' || pi.status === 'canceled') {
      return { status: pi.status === 'canceled' ? 'canceled' : 'done', payment_intent: pi.id };
    }
    res = await term.present(pi);
  } else {
    res = await term.collect({
      amountCents: plan.amount_cents, currency: plan.currency, idempotencyKey: piIdempotencyKey(plan.order_id), orderId: plan.order_id,
    });
  }
  if (res.status === 'canceled') return { status: 'canceled', payment_intent: res.terminalRef ?? null };
  return { status: 'processing', payment_intent: res.terminalRef ?? null, ...(res.clientSecret && plan.mode === 'sdk' ? { client_secret: res.clientSecret } : {}) };
}

export type AdvanceState = 'succeeded' | 'declined' | 'canceled' | 'waiting' | 'refunded';

export interface AdvanceResult {
  state: AdvanceState;
  /** The order (the walk-up order JSON) once completed or cancelled. */
  order?: unknown;
  decline_code?: string | null;
  /** Captured but the sale couldn't complete: refunded in full. */
  refund?: { id: string | null; status: string } | null;
}

/** Refund a capture that couldn't become tickets (the whole charge), and record it. */
export async function refundUnfulfilled(db: CardDb, stripe: TerminalStripe, orderId: string, pi: string): Promise<{ id: string | null; status: string }> {
  // A Stripe error throws: the row stays refund_pending and the next poll or
  // webhook delivery retries with the same key (the same refund).
  const r = await stripe.createRefund({
    payment_intent: pi, reason: 'requested_by_customer',
    ...refundFlags('destination', { commissionInFee: true }),
    metadata: { [POS_METADATA_KEY]: orderId, exos_auto: 'fulfillment_failed' },
  }, { idempotencyKey: autoRefundIdempotencyKey(orderId) });
  const status = r.status === 'succeeded' || r.status === 'failed' || r.status === 'canceled' ? r.status : 'pending';
  await call(db, '_exos_pos_card_refund_record', { p_order: orderId, p_refund_ref: r.id, p_status: status, p_error: r.failure_reason ?? null });
  return { id: r.id, status };
}

async function complete(db: CardDb, stripe: TerminalStripe, orderId: string, pi: IntentLike, via: 'door' | 'webhook', eventId?: string): Promise<AdvanceResult> {
  const amount = pi.amount_received ?? pi.amount ?? 0;
  const r = await call<{ refund_needed?: boolean } & Record<string, unknown>>(db, '_exos_pos_card_complete', {
    p_order: orderId, p_pi: pi.id, p_amount: amount, p_via: via, p_event_id: eventId ?? null,
  });
  if (r?.refund_needed) {
    const refund = await refundUnfulfilled(db, stripe, orderId, pi.id);
    return { state: 'refunded', order: r, refund };
  }
  return { state: 'succeeded', order: r };
}

async function fail(db: CardDb, orderId: string, pi: string | null, status: 'declined' | 'canceled', code: string | null, via: 'door' | 'webhook', reason?: string): Promise<AdvanceResult> {
  const r = await call<Record<string, unknown>>(db, '_exos_pos_card_fail', {
    p_order: orderId, p_pi: pi, p_status: status, p_code: cleanDeclineCode(code), p_via: via, p_reason: reason ?? null,
  });
  return { state: status, order: r, decline_code: cleanDeclineCode(code) };
}

/**
 * Move a card sale along from the PaymentIntent's state: capture and
 * complete, complete, or cancel. Safe to run from the door and the webhook
 * at the same time: the capture is idempotency-keyed per PaymentIntent and
 * the completion is idempotent on the order.
 */
export async function advanceCard(
  db: CardDb, stripe: TerminalStripe, orderId: string, pi: IntentLike,
  ctx: { via: 'door' | 'webhook'; eventId?: string; action?: ReaderActionLike | null },
): Promise<AdvanceResult> {
  const s = cardStep(pi, ctx.action);
  switch (s.step) {
    case 'capture': {
      const prep = await call<{ action: 'capture' | 'done' | 'cancel' | 'ignore' }>(db, '_exos_pos_card_capture_prepare', { p_order: orderId, p_pi: pi.id });
      if (prep.action === 'ignore') return { state: 'waiting' };
      // The other path completed it: the completion answers as a replay.
      if (prep.action === 'done') return await complete(db, stripe, orderId, pi, ctx.via, ctx.eventId);
      if (prep.action === 'cancel') {
        await stripe.cancelPaymentIntent(pi.id).catch(() => undefined);
        return await fail(db, orderId, pi.id, 'canceled', null, ctx.via, 'the places were given back before the card was captured');
      }
      let captured: IntentLike;
      try {
        captured = await stripe.capturePaymentIntent(pi.id, { idempotencyKey: captureIdempotencyKey(pi.id) });
      } catch (e) {
        // Captured by the other path already (a different request), or gone:
        // read where it is now and carry on from there.
        captured = await stripe.retrievePaymentIntent(pi.id);
        if (captured.status === 'requires_capture') throw e;
      }
      if (captured.status === 'succeeded') return await complete(db, stripe, orderId, captured, ctx.via, ctx.eventId);
      if (captured.status === 'canceled') return await fail(db, orderId, pi.id, 'canceled', null, ctx.via);
      return { state: 'waiting' };
    }
    case 'complete':
      return await complete(db, stripe, orderId, pi, ctx.via, ctx.eventId);
    case 'canceled':
      return await fail(db, orderId, pi.id, 'canceled', null, ctx.via);
    case 'declined':
      // The reader may still offer another card; Exos ends the sale instead
      // (docs/pos.md): cancel the PaymentIntent first so nothing can capture.
      await stripe.cancelPaymentIntent(pi.id).catch(() => undefined);
      return await fail(db, orderId, pi.id, 'declined', s.code, ctx.via, 'card declined');
    default:
      return { state: 'waiting' };
  }
}

/**
 * Cancel a pending card sale from the door: stop the reader, cancel the
 * PaymentIntent, cancel the sale. If the card was captured meanwhile the
 * sale completes instead (state 'succeeded').
 */
export async function cancelCard(
  db: CardDb, stripe: TerminalStripe, orderId: string,
  lookup: { payment_intent_id: string | null; reader_id: string | null },
  reason: string,
): Promise<AdvanceResult> {
  if (lookup.reader_id) await stripe.cancelReaderAction(lookup.reader_id).catch(() => undefined);
  if (lookup.payment_intent_id) {
    try {
      await stripe.cancelPaymentIntent(lookup.payment_intent_id);
    } catch {
      const pi = await stripe.retrievePaymentIntent(lookup.payment_intent_id);
      if (pi.status === 'succeeded' || pi.status === 'requires_capture') {
        // Too late to cancel an authorized / captured card: finish the sale
        // (the staff can void it, which refunds the card).
        return await advanceCard(db, stripe, orderId, pi, { via: 'door' });
      }
      if (pi.status !== 'canceled') throw new Error('the reader is still busy with this card: try again');
    }
  }
  return await fail(db, orderId, lookup.payment_intent_id, 'canceled', null, 'door', reason);
}

/** What _exos_pos_card_reverse answers about the card part. */
export interface CardRefundState {
  payment_intent: string;
  amount_cents: number;
  status: string | null;
  refund_ref: string | null;
}

/**
 * The Stripe refund of a voided / refunded card sale, after the reversal is
 * on the ledger (pending). Same key and parameters on every retry; a refund
 * already settled is not asked again.
 */
export async function refundCardSale(
  db: CardDb, stripe: TerminalStripe, orderId: string, card: CardRefundState, opts: CardFlowOpts = {},
): Promise<{ id: string | null; status: string; error?: string }> {
  if (card.status === 'succeeded' || (card.refund_ref && card.status === 'pending')) {
    return { id: card.refund_ref, status: card.status ?? 'pending' };
  }
  let id: string | null = null;
  let status = 'pending';
  let error: string | undefined;
  try {
    const r = await stripe.createRefund({
      payment_intent: card.payment_intent, amount: card.amount_cents, reason: 'requested_by_customer',
      ...refundFlagsForMode('standard', opts.keepPlatformFee === true),
      metadata: { [POS_METADATA_KEY]: orderId },
    }, { idempotencyKey: refundIdempotencyKey(orderId) });
    id = r.id;
    status = r.status === 'succeeded' || r.status === 'failed' || r.status === 'canceled' ? r.status : 'pending';
    error = r.failure_reason ?? undefined;
  } catch (e) {
    // Stripe said no and created nothing: record it failed (an operator
    // refunds by hand). Anything else may have created a refund: stays
    // pending, and the same request retries with the same key.
    const t = stripeType(e);
    if (t === 'StripeInvalidRequestError' || t === 'StripeCardError' || t === 'StripePermissionError') {
      status = 'failed';
      error = stripeCode(e) || (e as Error).message;
    } else {
      return { id: null, status: 'pending', error: 'the card refund will be retried' };
    }
  }
  await call(db, '_exos_pos_card_refund_record', { p_order: orderId, p_refund_ref: id, p_status: status, p_error: error ?? null });
  return { id, status, ...(error ? { error } : {}) };
}

// ---------------------------------------------------------------------------
// The webhook fallback.
// ---------------------------------------------------------------------------

export const POS_INTENT_EVENTS = new Set([
  'payment_intent.amount_capturable_updated',
  'payment_intent.succeeded',
  'payment_intent.payment_failed',
  'payment_intent.canceled',
]);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The walk-up order a PaymentIntent belongs to (its metadata), or null when it isn't a door sale. */
export function posOrderOf(pi: { metadata?: Record<string, string> | null } | null | undefined): string | null {
  const v = pi?.metadata?.[POS_METADATA_KEY];
  return typeof v === 'string' && UUID_RE.test(v) ? v.toLowerCase() : null;
}

/**
 * stripe-webhook: a door sale whose app lost its connection still completes
 * (authorized -> captured -> tickets) or gives its places back (declined /
 * cancelled). Idempotent: the database gates every step on the order's state,
 * so a replayed event, or one arriving after the door finished, changes
 * nothing. Throws on a transient error (the webhook answers 500 and Stripe
 * retries). { handled: false } for a PaymentIntent that isn't a door sale.
 */
export async function handlePosIntentEvent(
  db: CardDb, stripe: TerminalStripe, event: { id: string; type: string; data: { object: unknown } },
): Promise<{ handled: boolean; result?: AdvanceResult }> {
  if (!POS_INTENT_EVENTS.has(event.type)) return { handled: false };
  const pi = event.data.object as IntentLike;
  const orderId = posOrderOf(pi);
  if (!orderId || typeof pi?.id !== 'string') return { handled: false };
  let result: AdvanceResult;
  try {
    if (event.type === 'payment_intent.payment_failed') {
      const code = pi.last_payment_error?.decline_code ?? pi.last_payment_error?.code ?? null;
      await stripe.cancelPaymentIntent(pi.id).catch(() => undefined);
      result = await fail(db, orderId, pi.id, 'declined', code, 'webhook', 'card declined');
    } else {
      // The event's copy may be stale (the door may have moved it on): act on
      // the current state for a capture; the others are final states.
      const cur = event.type === 'payment_intent.amount_capturable_updated' ? await stripe.retrievePaymentIntent(pi.id) : pi;
      result = await advanceCard(db, stripe, orderId, { ...cur, metadata: pi.metadata }, { via: 'webhook', eventId: event.id });
    }
  } catch (e) {
    // An order the database doesn't know (deleted, another environment): nothing to do.
    if (e instanceof CardDbError && e.db.code === 'P0002') return { handled: true };
    throw e;
  }
  return { handled: true, result };
}
