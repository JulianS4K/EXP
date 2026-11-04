// The promoter wedge (mig 20261102150000): step commissions, settling,
// Stripe payout plans, instant payout fees, money so far, phone RSVP rules.
// The SQL side is tests/exos/test_promoter_wedge.sql (PW1-PW18).

import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import {
  canSendOrCancel, commissionCents, newSettleKey, payoutStatusLabel, stepFrom, termsForOrdinal, tieredLabel, tieredTotalCents,
} from './commissions';
import { admitted, moneySoFarText, normalizeMoneySoFar, takeHomeCents } from './moneySoFar';
import { rsvpHeads, ticketPathFromUrl } from './phoneRsvp';
import {
  codeSentText, codeText, honeypotAnswer, maskPhone, normalizeRsvpPhone, parseRsvpRequest, RsvpInputError, rsvpErrorMessage, smsAvailable, ticketsText,
} from '../../supabase/functions/_shared/rsvp.ts';
import { readFileSync } from 'node:fs';
import {
  CANCEL_AFTER_MS, DB_TIMEOUT_MS, findReturnTransfer, LEASE_MS, MAX_FUNDING_LINES, mayCallStripe, STRIPE_MAX_RETRIES,
  STRIPE_TIMEOUT_MS, worstSendMs,
} from '../../supabase/functions/_shared/payouts/promoterTransfers.ts';
import { drainRsvpSms } from '../../supabase/functions/_shared/sms/rsvpOutbox.ts';
import {
  amountToReturn, claimAction, durably, reconcileDecision, returnKey, reversalKey, sendPlan, stripeErrorText, transferKey, transfersMode, type TransferClaim,
} from '../../supabase/functions/_shared/payouts/promoterTransfers.ts';
import {
  checkInstantRequest, instantAvailable, instantEnabled, instantFeeCents, instantFeeConfig, maxInstantPayout,
} from '../../supabase/functions/_shared/payouts/instant.ts';

describe('step commissions', () => {
  const t = { rateBps: 1000, flatCents: 0, step: { after: 20, rateBps: 1500, flatCents: 0 } };
  it('applies the step after N tickets at the event (same rule as _exos_pc_terms)', () => {
    expect(termsForOrdinal(t, 20)).toEqual({ rateBps: 1000, flatCents: 0, stepped: false });
    expect(termsForOrdinal(t, 21)).toEqual({ rateBps: 1500, flatCents: 0, stepped: true });
    expect(termsForOrdinal({ rateBps: 500, flatCents: 25 }, 999)).toEqual({ rateBps: 500, flatCents: 25, stepped: false });
    expect(termsForOrdinal(t, 0).stepped).toBe(false);
  });
  it('totals a run of tickets across the step', () => {
    // 22 tickets at $20: 20 x $2 + 2 x $3
    expect(tieredTotalCents(t, 2000, 22)).toBe(20 * 200 + 2 * 300);
    expect(tieredTotalCents(t, 2000, 2, 19)).toBe(200 + 300);
    expect(tieredTotalCents(t, 2000, 0)).toBe(0);
    expect(commissionCents(2000, 1500, 0)).toBe(300);
  });
  it('reads the step from RPC columns and labels it', () => {
    expect(stepFrom(null, null, null)).toBeNull();
    expect(stepFrom(0, 1500, 0)).toBeNull();
    expect(stepFrom(20, 1500, 0)).toEqual({ after: 20, rateBps: 1500, flatCents: 0 });
    expect(tieredLabel(t)).toBe('10%, then 15% after 20 tickets');
    expect(tieredLabel({ rateBps: 1000, flatCents: 0, step: { after: 1, rateBps: 0, flatCents: 150 } })).toBe('10%, then $1.50 / ticket after 1 ticket');
    expect(tieredLabel({ rateBps: 1000, flatCents: 0 })).toBe('10%');
  });
});

describe('settling', () => {
  it('makes settle keys the SQL accepts', () => {
    const k = newSettleKey(() => '0f0f0000-1111-4222-8333-444455556666');
    expect(k).toMatch(/^[A-Za-z0-9_-]{8,80}$/);
    expect(newSettleKey()).not.toBe(newSettleKey());
  });
  it('labels payouts and says which can still be sent or cancelled', () => {
    expect(payoutStatusLabel('manual', null)).toBe('Recorded');
    expect(payoutStatusLabel('stripe', 'dry_run')).toMatch(/Dry run/);
    expect(payoutStatusLabel('stripe', 'sent')).toBe('Sent by Stripe');
    expect(canSendOrCancel('stripe', 'pending')).toBe(true);
    expect(canSendOrCancel('stripe', 'failed')).toBe(true);
    expect(canSendOrCancel('stripe', 'sent')).toBe(false);
    expect(canSendOrCancel('stripe', 'cancelled')).toBe(false);
    expect(canSendOrCancel('manual', 'pending')).toBe(false);
    // A half-finished cancel can be finished, never sent.
    expect(canSendOrCancel('stripe', 'return_pending')).toBe(true);
    expect(payoutStatusLabel('stripe', 'cancel_pending')).toMatch(/Cancelling/);
  });
});

describe('promoter transfer plans', () => {
  const claim = (over: Partial<TransferClaim> = {}): TransferClaim => ({
    payout_id: 'po1', org_id: 'o1', promoter_id: 'p1', amount_cents: 700, currency: 'USD', destination: 'acct_P',
    stripe_transfer_id: null,
    lines: [{ session_id: 'cs_1', org_transfer_id: 'tr_1', amount_cents: 500, status: 'planned', reversal_id: null },
            { session_id: 'cs_2', org_transfer_id: 'tr_2', amount_cents: 200, status: 'taken', reversal_id: 'trr_2' }],
    ...over,
  });
  it('is dry run unless EXOS_PROMOTER_TRANSFERS is exactly "on"', () => {
    expect(transfersMode(() => undefined)).toBe('dry-run');
    expect(transfersMode(() => 'true')).toBe('dry-run');
    expect(transfersMode((k) => (k === 'EXOS_PROMOTER_TRANSFERS' ? 'on' : undefined))).toBe('live');
  });
  it('reverses only planned lines and sends exactly the payout', () => {
    const p = sendPlan(claim());
    expect(p.ok).toBe(true);
    if (!p.ok) return;
    expect(p.reverse.map((l) => l.session_id)).toEqual(['cs_1']);
    expect(p.transfer).toEqual({ amount: 700, currency: 'usd', destination: 'acct_P' });
  });
  it('refuses a claim whose funding does not add up, or with no account', () => {
    expect(sendPlan(claim({ amount_cents: 701 })).ok).toBe(false);
    expect(sendPlan(claim({ destination: null })).ok).toBe(false);
    expect(sendPlan(claim({ amount_cents: 0 })).ok).toBe(false);
    expect(sendPlan(claim({ lines: [{ session_id: 'x', org_transfer_id: 'bad', amount_cents: 700, status: 'planned', reversal_id: null }] })).ok).toBe(false);
    // Released / returned lines don't count as funding.
    expect(sendPlan(claim({ lines: [{ session_id: 'x', org_transfer_id: 'tr_x', amount_cents: 700, status: 'released', reversal_id: null }] })).ok).toBe(false);
  });
  it('has deterministic idempotency keys and returns only what was taken', () => {
    expect(reversalKey('po1', 'cs_1')).toBe('exos-pcf:po1:cs_1');
    expect(transferKey('po1')).toBe('exos-pct:po1');
    expect(returnKey('po1')).toBe('exos-pcr:po1');
    expect(amountToReturn(claim().lines)).toBe(200);
  });
  it('reconciles before a cancel: a found transfer means sent, never cancel', () => {
    const c = claim({ lines: [{ session_id: 'cs_1', org_transfer_id: 'tr_1', amount_cents: 700, status: 'planned', reversal_id: null }] });
    const meta = { exos_promoter_payout_id: 'po1' };
    // Nothing at Stripe: the cancel may go ahead.
    expect(reconcileDecision(c, [], {})).toEqual({ action: 'allow_cancel', transferId: null, reversals: [] });
    // A reversal went through but no transfer: record the reversal, cancel returns it.
    expect(reconcileDecision(c, [], { cs_1: [{ id: 'trr_9', metadata: { ...meta, exos_session_id: 'cs_1' } }] }))
      .toEqual({ action: 'allow_cancel', transferId: null, reversals: [{ session_id: 'cs_1', reversal_id: 'trr_9' }] });
    // The promoter transfer exists: mark sent.
    expect(reconcileDecision(c, [{ id: 'tr_out', destination: 'acct_P', metadata: meta }], {}).action).toBe('mark_sent');
    // The organizer-return transfer, another payout's transfer, or another destination don't count.
    expect(reconcileDecision(c, [{ id: 'tr_ret', destination: 'acct_P', metadata: { ...meta, exos_return: '1' } }], {}).action).toBe('allow_cancel');
    expect(reconcileDecision(c, [{ id: 'tr_x', destination: 'acct_P', metadata: { exos_promoter_payout_id: 'po2' } }], {}).action).toBe('allow_cancel');
    expect(reconcileDecision(c, [{ id: 'tr_y', destination: 'acct_Z', metadata: meta }], {}).action).toBe('allow_cancel');
    // Another payout's reversal on the same order transfer isn't ours.
    expect(reconcileDecision(c, [], { cs_1: [{ id: 'trr_8', metadata: { exos_promoter_payout_id: 'po2', exos_session_id: 'cs_1' } }] }).reversals).toEqual([]);
  });
  it('decides what a claim allows: proceed, reconcile first, or stop', () => {
    const tok = '0f0f0000-1111-4222-8333-444455556666';
    const base = claim();
    expect(claimAction({ ok: true, purpose: 'send', lease_token: tok, attempt: 1, ...base })).toBe('proceed');
    // A retried send whose earlier attempt was never reconciled.
    expect(claimAction({ ok: false, error: 'needs_reconcile' })).toBe('reconcile_first');
    // A cancel (or reconcile) after a started send.
    expect(claimAction({ ok: true, purpose: 'cancel', lease_token: tok, needs_reconcile: true, ...base })).toBe('reconcile_first');
    expect(claimAction({ ok: true, purpose: 'cancel', lease_token: tok, needs_reconcile: false, ...base })).toBe('proceed');
    // An open send, a sent or cancelled payout, a missing lease: stop.
    expect(claimAction({ ok: false, error: 'send_in_progress' })).toEqual({ stop: 'send_in_progress' });
    expect(claimAction({ ok: false, error: 'sent' })).toEqual({ stop: 'sent' });
    expect(claimAction({ ok: true, purpose: 'send', lease_token: '', ...base })).toEqual({ stop: 'no lease' });
    // After a reconcile finds the transfer, the send creates nothing: mark_sent.
    const meta = { exos_promoter_payout_id: 'po1' };
    expect(reconcileDecision(base, [{ id: 'tr_done', destination: 'acct_P', metadata: meta }], {}))
      .toMatchObject({ action: 'mark_sent', transferId: 'tr_done' });
  });
  it('retries a ledger write and reports a write that never sticks', async () => {
    let n = 0;
    expect(await durably(async () => ++n >= 2, 3, 0)).toBe(true);
    expect(await durably(async () => { throw new Error('db down'); }, 3, 0)).toBe(false);
    expect(await durably(async () => false, 2, 0)).toBe(false);
  });
  it('keeps secrets out of Stripe error text', () => {
    expect(stripeErrorText({ code: 'balance_insufficient', message: 'No funds for sk_live_abc123' })).toBe('balance_insufficient: No funds for [key]');
    expect(stripeErrorText(null)).toBe('Stripe error');
  });
});

describe('payout timing bounds', () => {
  it('a whole send ends before its lease, and the lease before a cancel may start', () => {
    expect(STRIPE_TIMEOUT_MS).toBe(15_000);
    expect(STRIPE_MAX_RETRIES).toBeLessThanOrEqual(1);
    expect(worstSendMs()).toBe(11 * 15_000 + 45 * DB_TIMEOUT_MS + 11 * 750);
    expect(worstSendMs()).toBeLessThan(LEASE_MS);
    expect(LEASE_MS).toBeLessThan(CANCEL_AFTER_MS);
    expect(mayCallStripe(0)).toBe(true);
    expect(mayCallStripe(LEASE_MS - STRIPE_TIMEOUT_MS)).toBe(false);
    expect(mayCallStripe(-1)).toBe(false);
  });
  it('the SQL uses the same numbers', () => {
    const sql = readFileSync(new URL('../../supabase/migrations/20261102150000_exos_promoter_wedge.sql', import.meta.url), 'utf8');
    const claim = sql.slice(sql.indexOf('CREATE OR REPLACE FUNCTION public.exos_promoter_transfer_claim'),
                            sql.indexOf('CREATE OR REPLACE FUNCTION public.exos_promoter_lease_ok'));
    expect(claim).toContain(`lease_until = now() + interval '${LEASE_MS / 60_000} minutes'`);
    expect(claim).toContain(`po.send_started_at > now() - interval '${CANCEL_AFTER_MS / 60_000} minutes'`);
    expect(sql).toContain(`WHERE payout_id = v_id) > ${MAX_FUNDING_LINES} THEN`);
    const leaseOk = sql.slice(sql.indexOf('CREATE OR REPLACE FUNCTION public.exos_promoter_lease_ok'),
                              sql.indexOf('CREATE OR REPLACE FUNCTION public.exos_promoter_funding_mark'));
    expect(leaseOk).not.toMatch(/SET\s+lease_until/);   // never extended
  });
  it('finds an earlier run\'s return transfer on a retried cancel', () => {
    const m = { exos_promoter_payout_id: 'po1' };
    expect(findReturnTransfer('po1', [{ id: 'tr_out', metadata: m }, { id: 'tr_ret', metadata: { ...m, exos_return: '1' } }])).toBe('tr_ret');
    expect(findReturnTransfer('po1', [{ id: 'tr_out', metadata: m }])).toBeNull();
    expect(findReturnTransfer('po1', [{ id: 'tr_x', metadata: { exos_promoter_payout_id: 'po2', exos_return: '1' } }])).toBeNull();
  });
  it('drains the RSVP resend outbox off the request path', async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const sb = { rpc: async (fn: string, args: Record<string, unknown>) => {
      calls.push([fn, args]);
      return fn === 'exos_rsvp_sms_claim'
        ? { data: [{ id: 'q1', org_id: 'o1', phone: '+12125550113', body: 'Your tickets' }], error: null }
        : { data: true, error: null };
    } };
    const fake = (async () => new Response(JSON.stringify({ sid: 'SM1' }), { status: 201 })) as unknown as typeof fetch;
    const cfg = { provider: 'twilio' as const, config: { account_sid: 'AC' + '0'.repeat(32), from: '+12125550000' }, secret: 's' };
    expect(await drainRsvpSms(sb, true, async () => cfg, fake)).toEqual({ sent: 1, failed: 0 });
    expect(calls.at(-1)).toEqual(['exos_rsvp_sms_mark', { p_id: 'q1', p_status: 'sent' }]);
    expect(await drainRsvpSms(sb, false, async () => cfg, fake)).toEqual({ sent: 0, failed: 1 });
  });
});

describe('instant payouts', () => {
  const cfg = { bps: 150, minCents: 50 };
  it('is off unless EXOS_INSTANT_PAYOUTS is "on"; fee config has safe defaults', () => {
    expect(instantEnabled(() => undefined)).toBe(false);
    expect(instantEnabled(() => 'on')).toBe(true);
    expect(instantFeeConfig(() => undefined)).toEqual(cfg);
    expect(instantFeeConfig((k) => (k === 'EXOS_INSTANT_PAYOUT_FEE_BPS' ? '100' : k === 'EXOS_INSTANT_PAYOUT_FEE_MIN_CENTS' ? '25' : undefined))).toEqual({ bps: 100, minCents: 25 });
    expect(instantFeeConfig(() => '-5')).toEqual(cfg);
  });
  it('estimates the fee (1.5%, at least 50c, rounded up)', () => {
    expect(instantFeeCents(10000, cfg)).toBe(150);
    expect(instantFeeCents(1000, cfg)).toBe(50);
    expect(instantFeeCents(3333, cfg)).toBe(50);
    expect(instantFeeCents(100001, cfg)).toBe(1501);
    expect(instantFeeCents(0, cfg)).toBe(0);
  });
  it('caps the payout so amount + fee fits the instant balance', () => {
    const max = maxInstantPayout(10150, cfg);
    expect(max + instantFeeCents(max, cfg)).toBeLessThanOrEqual(10150);
    expect(max + 1 + instantFeeCents(max + 1, cfg)).toBeGreaterThan(10150);
    expect(maxInstantPayout(50, cfg)).toBe(0);
    expect(maxInstantPayout(200, cfg)).toBe(150);
  });
  it('normalizes the balance and checks a request', () => {
    const av = instantAvailable({ instant_available: [{ amount: 10150, currency: 'USD' }, { amount: 0, currency: 'eur' }, { amount: 5 }] });
    expect(av).toEqual([{ currency: 'usd', amount_cents: 10150 }]);
    expect(checkInstantRequest({ amount_cents: 10000, currency: 'usd', idempotency_key: 'k-12345678' }, av, cfg)).toEqual(
      { ok: true, amount: 10000, currency: 'usd', fee: 150, key: 'k-12345678' });
    expect(checkInstantRequest({ amount_cents: 10100, currency: 'usd', idempotency_key: 'k-12345678' }, av, cfg).ok).toBe(false);
    expect(checkInstantRequest({ amount_cents: 99, currency: 'usd', idempotency_key: 'k-12345678' }, av, cfg).ok).toBe(false);
    expect(checkInstantRequest({ amount_cents: 1000, currency: 'eur', idempotency_key: 'k-12345678' }, av, cfg).ok).toBe(false);
    expect(checkInstantRequest({ amount_cents: 1000, currency: 'usd', idempotency_key: 'short' }, av, cfg).ok).toBe(false);
  });
});

describe('money so far', () => {
  const m = normalizeMoneySoFar({
    event_id: 'e1', name: 'Night', currency: 'USD',
    online: { orders: 4, gross_cents: 12000, fees_cents: 2290, refunded_cents: 0, net_cents: 9710, paypal_net_cents: 0, last_hour_gross_cents: 2000 },
    door: { cash_cents: 5000, card_cents: 3000, tips_cents: 400 },
    tickets: { paid: 6, free: 3, comps: 1, phone_rsvps: 2, checked_in: 4 },
    promoters: { owed_cents: 500, paid_cents: 900 },
  })!;
  it('fills missing numbers with zeros and lower-cases the currency', () => {
    expect(m.currency).toBe('usd');
    expect(m.online.tax_cents).toBe(0);
    expect(m.door.comp_cents).toBe(0);
    expect(normalizeMoneySoFar(null)).toBeNull();
  });
  it('take-home is online net + door, less commission still owed', () => {
    expect(takeHomeCents(m)).toBe(9710 + 5000 + 3000 - 500);
    expect(admitted(m)).toBe(10);
  });
  it('writes a group-chat summary', () => {
    const txt = moneySoFarText(m, (c) => `$${(c / 100).toFixed(2)}`);
    expect(txt).toContain('Night: money so far');
    expect(txt).toContain('$120.00 gross from 4 orders');
    expect(txt).toContain('Door: $50.00 cash, $30.00 card, $4.00 tips');
    expect(txt).toContain('Promoters: $5.00 owed, $9.00 paid');
    expect(txt).toContain('Take-home so far: $172.10');
    expect(txt).toContain('3 free (2 by phone)');
  });
});

describe('phone RSVP', () => {
  it('normalizes numbers like exos_sms_normalize_phone', () => {
    expect(normalizeRsvpPhone('(212) 555-0100')).toBe('+12125550100');
    expect(normalizeRsvpPhone('1 212 555 0100')).toBe('+12125550100');
    expect(normalizeRsvpPhone('+44 7700 900123')).toBe('+447700900123');
    expect(normalizeRsvpPhone('555-0100')).toBeNull();
    expect(normalizeRsvpPhone(12125550100)).toBeNull();
    expect(maskPhone('+12125550123')).toBe('•••• 0123');
  });
  it('parses requests and rejects bad ones', () => {
    const ev = '0f0f0000-0000-4000-8000-0000000000e2';
    expect(parseRsvpRequest({ action: 'info', event_id: ev })).toEqual({ action: 'info', eventId: ev, honeypot: false });
    const s = parseRsvpRequest({ action: 'start', event_id: ev, name: ' Ana ', phone: '2125550100', plus_ones: 1, website: '' });
    expect(s).toMatchObject({ name: 'Ana', plusOnes: 1, email: null, promoter: null, honeypot: false });
    expect(parseRsvpRequest({ action: 'start', event_id: ev, name: 'Bot', phone: '1', website: 'http://spam' }).honeypot).toBe(true);
    expect(parseRsvpRequest({ action: 'verify', rsvp_id: ev, code: ' 123 456 ' })).toMatchObject({ code: '123456' });
    for (const bad of [
      { action: 'nope' }, { action: 'info', event_id: 'x' }, { action: 'start', event_id: ev, phone: '2125550100' },
      { action: 'start', event_id: ev, name: 'A', phone: '2125550100', plus_ones: 12 },
      { action: 'start', event_id: ev, name: 'A', phone: '2125550100', promoter: 'bad code' },
      { action: 'verify', rsvp_id: ev, code: '12345' },
    ]) expect(() => parseRsvpRequest(bad)).toThrow(RsvpInputError);
  });
  it('answers a honeypot like a real start, and texts stay short', () => {
    expect(honeypotAnswer('start')).toMatchObject({ ok: true, channel: 'sms' });
    expect(honeypotAnswer('verify')).toMatchObject({ ok: false });
    expect(codeText('Warehouse Party', '123456')).toBe("123456 is your code to RSVP for Warehouse Party. It works for 10 minutes. Don't share it.");
    expect(ticketsText('X', ['https://a/t/1#k=k'])).toContain('https://a/t/1#k=k');
    expect(ticketsText('X', ['u1', 'u2'])).toContain('+1: u2');
    expect(codeText('x'.repeat(200), '000000').length).toBeLessThan(160);
    // The email line never claims a code was sent (same answer either way).
    expect(codeSentText('email', 'ma***@evil.com')).toMatch(/^If this number and email can RSVP/);
    expect(codeSentText('sms', '•••• 0113')).toContain('texted');
  });
  it('texts only with a live, connected provider', () => {
    expect(smsAvailable(false, { status: 'connected', secret: 's' })).toBe(false);
    expect(smsAvailable(true, null)).toBe(false);
    expect(smsAvailable(true, { status: 'connected', secret: null })).toBe(false);
    expect(smsAvailable(true, { status: 'error', secret: 's' })).toBe(false);
    expect(smsAvailable(true, { status: 'unverified', secret: 's' })).toBe(true);
  });
  it('has a message for every error the SQL answers', () => {
    for (const e of ['bad_phone', 'bad_name', 'bad_email', 'too_many_guests', 'sold_out', 'no_channel', 'rate_limited',
                     'wrong_code', 'locked', 'expired', 'used', 'off', 'closed', 'over']) {
      expect(rsvpErrorMessage(e)).not.toBe(rsvpErrorMessage('???'));
    }
    expect(rsvpErrorMessage('wrong_code', { attempts_left: 1 })).toContain('1 try left');
    expect(rsvpErrorMessage('too_many_guests', { max_plus_ones: 2 })).toContain('up to 2 guests');
  });
  it('turns a ticket link into an app path and counts heads', () => {
    const key = 'A'.repeat(43);
    expect(ticketPathFromUrl(`https://exos.example/t/0f0f0000-0000-4000-8000-000000000001#k=${key}`))
      .toBe(`/t/0f0f0000-0000-4000-8000-000000000001#k=${key}`);
    expect(ticketPathFromUrl('https://evil.example/x')).toBeNull();
    expect(ticketPathFromUrl(null)).toBeNull();
    expect(rsvpHeads([{ status: 'confirmed', plusOnes: 2 }, { status: 'confirmed', plusOnes: 0 }, { status: 'sold_out', plusOnes: 3 }])).toBe(4);
  });
});
