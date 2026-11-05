import { describe, expect, it } from 'vitest';
import {
  advanceCard, cancelCard, CardDbError, cardFeeSplit, cardPaymentIntentParams, cardStep, cardSwitch, handlePosIntentEvent,
  isRegistrationCode, posOrderOf, refundCardSale, startCardPayment, StripeTerminal, terminalAddress, terminalCardFee,
  type CardDb, type CardPlan, type IntentLike, type TerminalStripe,
} from '../../../supabase/functions/_shared/pos/stripeTerminal.ts';
import { checkoutFeeSplit } from '../../../supabase/functions/_shared/platformFee.ts';
import { STRIPE_TERMINAL_FEE } from '../../../supabase/functions/_shared/pos/settlement.ts';

const ORDER = '11111111-2222-4333-8444-555555555555';
const PLAN: CardPlan = {
  done: false, order_id: ORDER, event_id: 'e0000000-0000-4000-8000-000000000001', org_id: 'o0000000-0000-4000-8000-000000000001',
  amount_cents: 5000, currency: 'usd', fee_bps: 300, fee_base: 'card-tickets', destination: 'acct_Org1', location_id: 'tml_Loc1',
  reader_id: 'tmr_Door1', mode: 'reader', payment_intent_id: null, status: 'awaiting', description: 'Fall Party (door)',
};

/** A scripted Stripe: records every call; PaymentIntents live in a map. */
function fakeStripe(init: Partial<Record<string, IntentLike>> = {}) {
  const calls: { op: string; args: unknown[] }[] = [];
  const pis = new Map<string, IntentLike>(Object.entries(init) as [string, IntentLike][]);
  let seq = 0;
  const fail: Record<string, unknown> = {};
  const stripe: TerminalStripe = {
    async createPaymentIntent(params, opts) {
      calls.push({ op: 'create', args: [params, opts] });
      const id = `pi_Fake${++seq}`;
      const pi: IntentLike = { id, status: 'requires_payment_method', amount: params.amount, client_secret: `${id}_secret_x`, metadata: params.metadata };
      pis.set(id, pi);
      return pi;
    },
    async retrievePaymentIntent(id) {
      calls.push({ op: 'retrieve', args: [id] });
      const pi = pis.get(id);
      if (!pi) throw Object.assign(new Error('No such payment_intent'), { type: 'StripeInvalidRequestError' });
      return pi;
    },
    async capturePaymentIntent(id, opts) {
      calls.push({ op: 'capture', args: [id, opts] });
      if (fail.capture) throw fail.capture;
      const pi = pis.get(id)!;
      pi.status = 'succeeded';
      pi.amount_received = pi.amount;
      return pi;
    },
    async cancelPaymentIntent(id) {
      calls.push({ op: 'cancel', args: [id] });
      if (fail.cancel) throw fail.cancel;
      const pi = pis.get(id);
      if (pi) pi.status = 'canceled';
      return pi ?? { id, status: 'canceled' };
    },
    async processPaymentIntent(reader, pi) {
      calls.push({ op: 'process', args: [reader, pi] });
      return { id: reader };
    },
    async cancelReaderAction(reader) {
      calls.push({ op: 'cancelAction', args: [reader] });
      return { id: reader };
    },
    async retrieveReader(reader) {
      calls.push({ op: 'reader', args: [reader] });
      return { id: reader, action: null };
    },
    async createRefund(params, opts) {
      calls.push({ op: 'refund', args: [params, opts] });
      if (fail.refund) throw fail.refund;
      return { id: 're_Fake1', status: 'succeeded' };
    },
  };
  return { stripe, calls, pis, fail, ops: () => calls.map((c) => c.op) };
}

/** A scripted database: answers per function, records the calls. */
function fakeDb(answers: Record<string, unknown | ((args: Record<string, unknown>) => unknown)> = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const db: CardDb = {
    async rpc(fn, args) {
      calls.push({ fn, args });
      const a = answers[fn];
      const v = typeof a === 'function' ? (a as (x: Record<string, unknown>) => unknown)(args) : a;
      if (v instanceof CardDbError) return { data: null, error: v.db };
      return { data: v ?? {}, error: null };
    },
  };
  return { db, calls, fns: () => calls.map((c) => c.fn) };
}

describe('card switch (EXOS_POS_CARD)', () => {
  const env = (o: Record<string, string>) => (k: string) => o[k];
  it('is off unless EXOS_POS_CARD=on and a key is set', () => {
    expect(cardSwitch(env({}))).toEqual({ on: false, live: false, reason: 'off' });
    expect(cardSwitch(env({ EXOS_POS_CARD: 'on' }))).toEqual({ on: false, live: false, reason: 'no-key' });
    expect(cardSwitch(env({ EXOS_POS_CARD: 'on', STRIPE_SECRET_KEY: 'sk_test_x' }))).toEqual({ on: true, live: false });
    expect(cardSwitch(env({ EXOS_POS_CARD: 'yes', STRIPE_SECRET_KEY: 'sk_test_x' })).on).toBe(false);
  });
  it('a live key also needs EXOS_POS_CARD_LIVE=on', () => {
    expect(cardSwitch(env({ EXOS_POS_CARD: 'on', STRIPE_SECRET_KEY: 'sk_live_x' }))).toEqual({ on: false, live: true, reason: 'live-not-allowed' });
    expect(cardSwitch(env({ EXOS_POS_CARD: 'on', STRIPE_SECRET_KEY: 'rk_live_x', EXOS_POS_CARD_LIVE: 'on' }))).toEqual({ on: true, live: true });
  });
  it('the card fee is Terminal\'s in-person rate unless overridden', () => {
    expect(terminalCardFee(() => undefined)).toEqual(STRIPE_TERMINAL_FEE);
    expect(terminalCardFee((k) => ({ EXOS_STRIPE_TERMINAL_FEE_BPS: '260', EXOS_STRIPE_TERMINAL_FEE_FIXED_CENTS: '10' } as Record<string, string>)[k]))
      .toEqual({ bps: 260, fixedCents: 10 });
    expect(terminalCardFee((k) => (k === 'EXOS_STRIPE_TERMINAL_FEE_BPS' ? 'x' : undefined))).toEqual(STRIPE_TERMINAL_FEE);
  });
});

describe('the PaymentIntent', () => {
  it('card_present, manual capture, the order\'s amount, a destination charge with the application fee', () => {
    const { params, idempotencyKey, fee } = cardPaymentIntentParams(PLAN);
    // 3% Exos (150) + Terminal 2.7% + 5c (135 + 5): the platform pays Stripe under destination charges.
    expect(fee).toEqual({ applicationFeeCents: 290, exosFeeCents: 150, cardFeeEstCents: 140, feeBps: 300 });
    expect(params).toEqual({
      amount: 5000, currency: 'usd', payment_method_types: ['card_present'], capture_method: 'manual',
      application_fee_amount: 290, transfer_data: { destination: 'acct_Org1' }, description: 'Fall Party (door)',
      metadata: { exos_pos_order: ORDER, exos_event_id: PLAN.event_id, exos_org_id: PLAN.org_id, exos_kind: 'pos_walkup' },
    });
    expect(idempotencyKey).toBe(`exos_pos_pi_${ORDER}`);
    expect('on_behalf_of' in params).toBe(false);
  });
  it('the fee is exos-checkout\'s split at the Terminal rate; free months / free tier pay the card fee only', () => {
    expect(cardFeeSplit(5000, 300)).toEqual(checkoutFeeSplit(5000, { bps: 300, card: STRIPE_TERMINAL_FEE }));
    expect(cardPaymentIntentParams({ ...PLAN, fee_bps: 0 }).params.application_fee_amount).toBe(140);
    expect(cardPaymentIntentParams({ ...PLAN, amount_cents: 4 }).params.application_fee_amount).toBe(4); // never more than the charge
  });
  it('on_behalf_of only when switched on; currency lower case', () => {
    const { params } = cardPaymentIntentParams({ ...PLAN, currency: 'USD' }, { onBehalfOf: true });
    expect(params.on_behalf_of).toBe('acct_Org1');
    expect(params.currency).toBe('usd');
  });
  it('refuses a bad amount or no connected account', () => {
    expect(() => cardPaymentIntentParams({ ...PLAN, amount_cents: 0 })).toThrow();
    expect(() => cardPaymentIntentParams({ ...PLAN, destination: '' })).toThrow();
  });
});

describe('setup inputs', () => {
  it('an address Stripe Terminal accepts', () => {
    expect(terminalAddress({ line1: ' 1 Main St ', city: 'Brooklyn', state: 'NY', postal_code: '11201', country: 'us' }))
      .toEqual({ address: { line1: '1 Main St', city: 'Brooklyn', state: 'NY', postal_code: '11201', country: 'US' } });
    expect(terminalAddress({ line1: '1 Main St', city: 'Brooklyn', postal_code: '11201', country: 'US' })).toHaveProperty('error');
    expect(terminalAddress({ line1: '10 Rue X', city: 'Paris', postal_code: '75001', country: 'FR' })).toHaveProperty('address');
    expect(terminalAddress({ line1: 'x', city: 'y', postal_code: 'z', country: 'USA' })).toHaveProperty('error');
    expect(terminalAddress(null)).toHaveProperty('error');
  });
  it('registration codes', () => {
    expect(isRegistrationCode('sepia-cerulean-aqua')).toBe(true);
    expect(isRegistrationCode('simulated-wpe')).toBe(true);
    expect(isRegistrationCode('a b')).toBe(false);
    expect(isRegistrationCode(42)).toBe(false);
  });
});

describe('the state machine', () => {
  it('maps the PaymentIntent (and the reader\'s action) to the next step', () => {
    expect(cardStep({ id: 'pi_1', status: 'requires_capture' })).toEqual({ step: 'capture' });
    expect(cardStep({ id: 'pi_1', status: 'succeeded' })).toEqual({ step: 'complete' });
    expect(cardStep({ id: 'pi_1', status: 'canceled' })).toEqual({ step: 'canceled' });
    expect(cardStep({ id: 'pi_1', status: 'requires_payment_method' })).toEqual({ step: 'waiting' });
    expect(cardStep({ id: 'pi_1', status: 'processing' })).toEqual({ step: 'waiting' });
    expect(cardStep({ id: 'pi_1', status: 'requires_payment_method', last_payment_error: { code: 'card_declined', decline_code: 'insufficient_funds' } }))
      .toEqual({ step: 'declined', code: 'insufficient_funds' });
    expect(cardStep({ id: 'pi_1', status: 'requires_payment_method' },
      { status: 'failed', failure_code: 'card_declined', process_payment_intent: { payment_intent: 'pi_1' } }))
      .toEqual({ step: 'declined', code: 'card_declined' });
    // A failed action on ANOTHER PaymentIntent says nothing about this one.
    expect(cardStep({ id: 'pi_1', status: 'requires_payment_method' },
      { status: 'failed', process_payment_intent: { payment_intent: 'pi_2' } })).toEqual({ step: 'waiting' });
  });
});

describe('charging (startCardPayment)', () => {
  it('server-driven reader: create once, record it, then send it to the reader', async () => {
    const s = fakeStripe();
    const d = fakeDb({ _exos_pos_card_attach: { cancel: false } });
    const r = await startCardPayment(d.db, s.stripe, PLAN);
    expect(r).toEqual({ status: 'processing', payment_intent: 'pi_Fake1' });
    expect(s.ops()).toEqual(['create', 'process']);
    expect(s.calls[0].args[1]).toEqual({ idempotencyKey: `exos_pos_pi_${ORDER}` });
    expect(s.calls[1].args).toEqual(['tmr_Door1', 'pi_Fake1']);
    expect(d.calls).toEqual([{ fn: '_exos_pos_card_attach', args: {
      p_order: ORDER, p_pi: 'pi_Fake1', p_amount: 5000, p_currency: 'usd', p_app_fee: 290, p_exos_fee: 150, p_card_fee: 140, p_fee_bps: 300,
    } }]);
  });
  it('SDK (Tap to Pay): no reader call, the client secret goes back', async () => {
    const s = fakeStripe();
    const d = fakeDb({ _exos_pos_card_attach: { cancel: false } });
    const r = await startCardPayment(d.db, s.stripe, { ...PLAN, mode: 'sdk', reader_id: null });
    expect(r).toEqual({ status: 'processing', payment_intent: 'pi_Fake1', client_secret: 'pi_Fake1_secret_x' });
    expect(s.ops()).toEqual(['create']);
  });
  it('the sale ended meanwhile: the new PaymentIntent is cancelled, never sent', async () => {
    const s = fakeStripe();
    const d = fakeDb({ _exos_pos_card_attach: { cancel: true } });
    expect((await startCardPayment(d.db, s.stripe, PLAN)).status).toBe('canceled');
    expect(s.ops()).toEqual(['create', 'cancel']);
  });
  it('a retry sends the same PaymentIntent again, no second one', async () => {
    const s = fakeStripe({ pi_Old: { id: 'pi_Old', status: 'requires_payment_method', amount: 5000 } });
    const d = fakeDb();
    const r = await startCardPayment(d.db, s.stripe, { ...PLAN, payment_intent_id: 'pi_Old', status: 'processing' });
    expect(r.payment_intent).toBe('pi_Old');
    expect(s.ops()).toEqual(['retrieve', 'process']);
    expect(d.calls).toEqual([]);
  });
  it('a database refusal stops before Stripe is asked to do anything else', async () => {
    const s = fakeStripe();
    const d = fakeDb({ _exos_pos_card_attach: new CardDbError({ code: '22023', message: 'mismatch' }) });
    await expect(startCardPayment(d.db, s.stripe, PLAN)).rejects.toBeInstanceOf(CardDbError);
    expect(s.ops()).toEqual(['create']);
  });
  it('StripeTerminal refuses tips (not built) and anything but a reader id', async () => {
    const s = fakeStripe();
    const t = new StripeTerminal(s.stripe, { orderId: ORDER, eventId: PLAN.event_id, orgId: PLAN.org_id, destination: 'acct_Org1', feeBps: 300, description: 'x' });
    await expect(t.connect('not-a-reader')).rejects.toThrow();
    await expect(t.collect({ amountCents: 5000, tipCents: 100, currency: 'usd', idempotencyKey: 'k', orderId: ORDER })).rejects.toThrow(/tips/);
    expect(s.calls).toEqual([]);
  });
});

describe('moving a sale along (advanceCard)', () => {
  const authorized = (): IntentLike => ({ id: 'pi_A', status: 'requires_capture', amount: 5000, metadata: { exos_pos_order: ORDER } });
  it('authorized: prepare under the lock, capture with the PaymentIntent\'s key, complete', async () => {
    const s = fakeStripe({ pi_A: authorized() });
    const d = fakeDb({ _exos_pos_card_capture_prepare: { action: 'capture' }, _exos_pos_card_complete: { status: 'paid', refund_needed: false } });
    const r = await advanceCard(d.db, s.stripe, ORDER, authorized(), { via: 'door' });
    expect(r.state).toBe('succeeded');
    expect(s.ops()).toEqual(['capture']);
    expect(s.calls[0].args[1]).toEqual({ idempotencyKey: 'exos_pos_capture_pi_A' });
    expect(d.calls[1]).toEqual({ fn: '_exos_pos_card_complete', args: { p_order: ORDER, p_pi: 'pi_A', p_amount: 5000, p_via: 'door', p_event_id: null } });
  });
  it('the places were given back: cancel the authorization, cancel the sale, no capture', async () => {
    const s = fakeStripe({ pi_A: authorized() });
    const d = fakeDb({ _exos_pos_card_capture_prepare: { action: 'cancel' } });
    const r = await advanceCard(d.db, s.stripe, ORDER, authorized(), { via: 'door' });
    expect(r.state).toBe('canceled');
    expect(s.ops()).toEqual(['cancel']);
    expect(d.fns()).toEqual(['_exos_pos_card_capture_prepare', '_exos_pos_card_fail']);
  });
  it('already done by the other path: a replay, no capture', async () => {
    const s = fakeStripe({ pi_A: authorized() });
    const d = fakeDb({ _exos_pos_card_capture_prepare: { action: 'done' }, _exos_pos_card_complete: { replay: true, refund_needed: false } });
    expect((await advanceCard(d.db, s.stripe, ORDER, authorized(), { via: 'webhook' })).state).toBe('succeeded');
    expect(s.ops()).toEqual([]);
  });
  it('captured by the other request meanwhile: carry on from where Stripe is', async () => {
    const s = fakeStripe({ pi_A: { ...authorized(), status: 'succeeded', amount_received: 5000 } });
    s.fail.capture = Object.assign(new Error('already captured'), { type: 'StripeInvalidRequestError' });
    const d = fakeDb({ _exos_pos_card_capture_prepare: { action: 'capture' }, _exos_pos_card_complete: { refund_needed: false } });
    expect((await advanceCard(d.db, s.stripe, ORDER, authorized(), { via: 'door' })).state).toBe('succeeded');
    expect(s.ops()).toEqual(['capture', 'retrieve']);
  });
  it('a capture that fails while still authorized is retried later (throws)', async () => {
    const s = fakeStripe({ pi_A: authorized() });
    s.fail.capture = Object.assign(new Error('timeout'), { type: 'StripeConnectionError' });
    const d = fakeDb({ _exos_pos_card_capture_prepare: { action: 'capture' } });
    await expect(advanceCard(d.db, s.stripe, ORDER, authorized(), { via: 'door' })).rejects.toThrow('timeout');
    expect(d.fns()).toEqual(['_exos_pos_card_capture_prepare']);
  });
  it('captured but the sale can\'t complete: the whole charge is refunded with the auto-refund key', async () => {
    const pi: IntentLike = { id: 'pi_A', status: 'succeeded', amount: 5000, amount_received: 5000 };
    const s = fakeStripe({ pi_A: pi });
    const d = fakeDb({ _exos_pos_card_complete: { refund_needed: true }, _exos_pos_card_refund_record: { recorded: true } });
    const r = await advanceCard(d.db, s.stripe, ORDER, pi, { via: 'webhook', eventId: 'evt_1' });
    expect(r).toMatchObject({ state: 'refunded', refund: { id: 're_Fake1', status: 'succeeded' } });
    expect(s.calls[0].args).toEqual([{
      payment_intent: 'pi_A', reason: 'requested_by_customer', reverse_transfer: true, refund_application_fee: true,
      metadata: { exos_pos_order: ORDER, exos_auto: 'fulfillment_failed' },
    }, { idempotencyKey: `exos_pos_autorefund_${ORDER}` }]);
    expect(d.calls[1]).toEqual({ fn: '_exos_pos_card_refund_record', args: { p_order: ORDER, p_refund_ref: 're_Fake1', p_status: 'succeeded', p_error: null } });
  });
  it('declined: cancel the PaymentIntent first, then the sale, with the decline code', async () => {
    const pi: IntentLike = { id: 'pi_A', status: 'requires_payment_method', last_payment_error: { code: 'card_declined', decline_code: 'Do_Not_Honor' } };
    const s = fakeStripe({ pi_A: pi });
    const d = fakeDb({ _exos_pos_card_fail: { status: 'void' } });
    const r = await advanceCard(d.db, s.stripe, ORDER, pi, { via: 'door' });
    expect(r).toMatchObject({ state: 'declined', decline_code: 'do_not_honor' });
    expect(s.ops()).toEqual(['cancel']);
    expect(d.calls[0].args).toMatchObject({ p_status: 'declined', p_code: 'do_not_honor', p_pi: 'pi_A' });
  });
  it('still on the reader: nothing happens', async () => {
    const s = fakeStripe();
    const d = fakeDb();
    expect((await advanceCard(d.db, s.stripe, ORDER, { id: 'pi_A', status: 'requires_payment_method' }, { via: 'door' })).state).toBe('waiting');
    expect(s.calls).toEqual([]);
    expect(d.calls).toEqual([]);
  });
});

describe('cancel at the door (cancelCard)', () => {
  it('stops the reader, cancels the PaymentIntent, cancels the sale', async () => {
    const s = fakeStripe({ pi_A: { id: 'pi_A', status: 'requires_payment_method' } });
    const d = fakeDb({ _exos_pos_card_fail: { status: 'void' } });
    const r = await cancelCard(d.db, s.stripe, ORDER, { payment_intent_id: 'pi_A', reader_id: 'tmr_Door1' }, 'buyer left');
    expect(r.state).toBe('canceled');
    expect(s.ops()).toEqual(['cancelAction', 'cancel']);
    expect(d.calls[0].args).toMatchObject({ p_status: 'canceled', p_via: 'door', p_reason: 'buyer left' });
  });
  it('too late: the card was captured, so the sale completes (void it to refund)', async () => {
    const s = fakeStripe({ pi_A: { id: 'pi_A', status: 'succeeded', amount: 5000, amount_received: 5000 } });
    s.fail.cancel = Object.assign(new Error('cannot cancel'), { type: 'StripeInvalidRequestError' });
    const d = fakeDb({ _exos_pos_card_complete: { status: 'paid', refund_needed: false } });
    expect((await cancelCard(d.db, s.stripe, ORDER, { payment_intent_id: 'pi_A', reader_id: null }, 'x')).state).toBe('succeeded');
    expect(d.fns()).toEqual(['_exos_pos_card_complete']);
  });
});

describe('card refund of a sale (refundCardSale)', () => {
  const card = { payment_intent: 'pi_A', amount_cents: 5000, status: 'pending', refund_ref: null };
  it('refunds the card with the Connect flags of an online refund, then records Stripe\'s answer', async () => {
    const s = fakeStripe();
    const d = fakeDb();
    expect(await refundCardSale(d.db, s.stripe, ORDER, card)).toEqual({ id: 're_Fake1', status: 'succeeded' });
    expect(s.calls[0].args).toEqual([{
      payment_intent: 'pi_A', amount: 5000, reason: 'requested_by_customer', reverse_transfer: true, refund_application_fee: true,
      metadata: { exos_pos_order: ORDER },
    }, { idempotencyKey: `exos_pos_refund_${ORDER}` }]);
    expect(d.calls[0]).toEqual({ fn: '_exos_pos_card_refund_record', args: { p_order: ORDER, p_refund_ref: 're_Fake1', p_status: 'succeeded', p_error: null } });
  });
  it('EXOS_REFUND_KEEP_PLATFORM_FEE keeps the application fee', async () => {
    const s = fakeStripe();
    await refundCardSale(fakeDb().db, s.stripe, ORDER, card, { keepPlatformFee: true });
    expect((s.calls[0].args[0] as Record<string, unknown>).refund_application_fee).toBe(false);
  });
  it('a refund already settled or in flight is not asked again', async () => {
    const s = fakeStripe();
    await refundCardSale(fakeDb().db, s.stripe, ORDER, { ...card, status: 'succeeded', refund_ref: 're_1' });
    await refundCardSale(fakeDb().db, s.stripe, ORDER, { ...card, status: 'pending', refund_ref: 're_1' });
    expect(s.calls).toEqual([]);
  });
  it('Stripe said no: recorded failed; a network error: stays pending, nothing recorded', async () => {
    const s = fakeStripe();
    s.fail.refund = Object.assign(new Error('Charge already refunded'), { type: 'StripeInvalidRequestError', code: 'charge_already_refunded' });
    const d = fakeDb();
    expect(await refundCardSale(d.db, s.stripe, ORDER, card)).toMatchObject({ status: 'failed', error: 'charge_already_refunded' });
    expect(d.calls[0].args).toMatchObject({ p_status: 'failed', p_error: 'charge_already_refunded' });
    s.fail.refund = Object.assign(new Error('socket hang up'), { type: 'StripeConnectionError' });
    const d2 = fakeDb();
    expect((await refundCardSale(d2.db, s.stripe, ORDER, card)).status).toBe('pending');
    expect(d2.calls).toEqual([]);
  });
});

describe('the webhook fallback (handlePosIntentEvent)', () => {
  const ev = (type: string, pi: IntentLike) => ({ id: 'evt_1', type, data: { object: pi } });
  it('ignores PaymentIntents that aren\'t door sales, without a Stripe or database call', async () => {
    const s = fakeStripe();
    const d = fakeDb();
    expect(await handlePosIntentEvent(d.db, s.stripe, ev('payment_intent.succeeded', { id: 'pi_X', status: 'succeeded', metadata: { exos_session: 'cs_1' } })))
      .toEqual({ handled: false });
    expect(await handlePosIntentEvent(d.db, s.stripe, ev('charge.refunded', { id: 'pi_X', status: 'succeeded', metadata: { exos_pos_order: ORDER } })))
      .toEqual({ handled: false });
    expect(posOrderOf({ metadata: { exos_pos_order: 'not-a-uuid' } })).toBeNull();
    expect(s.calls).toEqual([]);
    expect(d.calls).toEqual([]);
  });
  it('the door app died after the tap: authorized -> captured -> completed by the webhook', async () => {
    const pi: IntentLike = { id: 'pi_W', status: 'requires_capture', amount: 5000, metadata: { exos_pos_order: ORDER } };
    const s = fakeStripe({ pi_W: { ...pi } });
    const d = fakeDb({ _exos_pos_card_capture_prepare: { action: 'capture' }, _exos_pos_card_complete: { status: 'paid', refund_needed: false } });
    const r = await handlePosIntentEvent(d.db, s.stripe, ev('payment_intent.amount_capturable_updated', pi));
    expect(r.result?.state).toBe('succeeded');
    expect(s.ops()).toEqual(['retrieve', 'capture']);
    expect(d.calls[1].args).toMatchObject({ p_via: 'webhook', p_event_id: 'evt_1', p_amount: 5000 });
  });
  it('succeeded after the door finished: the database answers a replay, nothing else happens', async () => {
    const pi: IntentLike = { id: 'pi_W', status: 'succeeded', amount: 5000, amount_received: 5000, metadata: { exos_pos_order: ORDER } };
    const s = fakeStripe();
    const d = fakeDb({ _exos_pos_card_complete: { replay: true, refund_needed: false } });
    const r = await handlePosIntentEvent(d.db, s.stripe, ev('payment_intent.succeeded', pi));
    expect(r.result?.state).toBe('succeeded');
    expect(s.calls).toEqual([]);
    expect(d.fns()).toEqual(['_exos_pos_card_complete']);
  });
  it('declined: the sale gives its places back', async () => {
    const pi: IntentLike = { id: 'pi_W', status: 'requires_payment_method', last_payment_error: { code: 'card_declined' }, metadata: { exos_pos_order: ORDER } };
    const s = fakeStripe({ pi_W: { ...pi } });
    const d = fakeDb({ _exos_pos_card_fail: { status: 'void' } });
    const r = await handlePosIntentEvent(d.db, s.stripe, ev('payment_intent.payment_failed', pi));
    expect(r.result).toMatchObject({ state: 'declined', decline_code: 'card_declined' });
    expect(s.ops()).toEqual(['cancel']);
    expect(d.calls[0].args).toMatchObject({ p_via: 'webhook', p_status: 'declined' });
  });
  it('an order the database doesn\'t know is done with; a database outage is retried', async () => {
    const pi: IntentLike = { id: 'pi_W', status: 'canceled', metadata: { exos_pos_order: ORDER } };
    const gone = fakeDb({ _exos_pos_card_fail: new CardDbError({ code: 'P0002', message: 'no card payment' }) });
    expect(await handlePosIntentEvent(gone.db, fakeStripe().stripe, ev('payment_intent.canceled', pi))).toEqual({ handled: true });
    const down = fakeDb({ _exos_pos_card_fail: new CardDbError({ code: '08006', message: 'connection failure' }) });
    await expect(handlePosIntentEvent(down.db, fakeStripe().stripe, ev('payment_intent.canceled', pi))).rejects.toBeInstanceOf(CardDbError);
  });
});
