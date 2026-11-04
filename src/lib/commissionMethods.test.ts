// Commission methods (mig 20261104190000): the pure maths (split shares,
// commission inside the fee, netting), the checkout / webhook / refund
// branching (destination vs split vs platform fee), the Exos-transfer helpers
// and the dashboard helpers. The SQL side is tests/exos/test_commission_methods.sql
// (CM1-CM14); the numbers below are the same cases.

import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  applicationFeeWithCommission, chargeModelFromMetadata, checkoutChargeMetadata, commissionEnv, ctClaimAction, ctLive,
  ctReconcileDecision, ctTransferKey, ctTransferParams, feeHeldCents, needsCommissionPlan, netOrganizerShare, nettedPayout,
  parsePlan, paymentIntentData, planChangesCharge, quoteTotal, refundFlags, RUN_BUDGET_MS, splitShares, trueUpCents,
  findSplitReversal, refundFlagsForMode, refundPrepAction, splitReversalKey,
  type CommissionPlan, type CtClaim,
} from '../../supabase/functions/_shared/payouts/commissionMethods.ts';
import { autoRefundParams } from '../../supabase/functions/_shared/auto-refund.ts';
import { organizerRefundParams } from '../../supabase/functions/_shared/organizer-refund.ts';
import { feeActualsFromCharge } from '../../supabase/functions/_shared/feeActuals.ts';
import { CANCEL_AFTER_MS, DB_TIMEOUT_MS, DURABLE_TRIES, LEASE_MS, STRIPE_TIMEOUT_MS } from '../../supabase/functions/_shared/payouts/promoterTransfers.ts';
import {
  holdbackText, METHOD_INFO, METHODS, needsFutureOnlyConfirm, nettingLine, normalizeBalances, parseHoldbackDays, resolveMethod,
} from './commissionMethods';

const GROUP = 'exos-order-11111111-2222-3333-4444-555555555555';
const plan = (o: Partial<CommissionPlan>): CommissionPlan => ({
  method: 'manual', source: 'org', promoter_id: null, charge_model: 'destination', application_fee_cents: 200,
  commission_fee_cents: 0, quote: [], transfer_group: null, ...o,
});

describe('split at sale: shares (mirrors _exos_split_entitlement)', () => {
  it('splits a charge into the Exos fee, the commission and the organizer share', () => {
    expect(splitShares({ amountCents: 4000, refundedCents: 0, applicationFeeCents: 200, commissionCents: 400 }))
      .toEqual({ net: 4000, fee: 200, commission: 400, orgShare: 3400 });
  });
  it('a refund before the transfer shrinks the shares; the fee goes back in proportion', () => {
    expect(splitShares({ amountCents: 4000, refundedCents: 2000, applicationFeeCents: 200, commissionCents: 200 }))
      .toEqual({ net: 2000, fee: 100, commission: 200, orgShare: 1700 });
  });
  it('a refund that keeps the tickets keeps the commission (the organizer bears it)', () => {
    expect(splitShares({ amountCents: 4000, refundedCents: 2000, applicationFeeCents: 200, commissionCents: 400 }).orgShare).toBe(1500);
  });
  it('never below zero; a lost dispute leaves nothing', () => {
    expect(splitShares({ amountCents: 6000, refundedCents: 6000, applicationFeeCents: 300, commissionCents: 600 }).orgShare).toBe(0);
    expect(splitShares({ amountCents: 2000, refundedCents: 0, applicationFeeCents: 100, commissionCents: 200, lostDispute: true }))
      .toEqual({ net: 0, fee: 0, commission: 200, orgShare: 0 });
  });
  it('floors the refunded fee share, caps refunds at the charge', () => {
    expect(splitShares({ amountCents: 1000, refundedCents: 1, applicationFeeCents: 333, commissionCents: 0 }).fee).toBe(333);
    expect(splitShares({ amountCents: 1000, refundedCents: 5000, applicationFeeCents: 100, commissionCents: 0 }).net).toBe(0);
  });
  it('true-up = share planned - share now (CM8: 3400 - 1500 = 1900, then 1700 after a void)', () => {
    expect(trueUpCents(3400, 1500)).toBe(1900);
    expect(trueUpCents(3400, 1700)).toBe(1700);
    expect(trueUpCents(1000, 1100)).toBe(-100);
  });
});

describe('inside the Exos fee', () => {
  it('Stripe is asked for the Exos fee plus the commission', () => {
    expect(applicationFeeWithCommission(200, 400)).toBe(600);
    expect(applicationFeeWithCommission(200, -5)).toBe(200);
  });
  it('what the fee still holds after a refund (rounds what went back up)', () => {
    expect(feeHeldCents(400, 4000, 1000)).toBe(300);
    expect(feeHeldCents(333, 1000, 1)).toBe(332);
    expect(feeHeldCents(400, 4000, 0)).toBe(400);
    expect(feeHeldCents(400, 4000, 9999)).toBe(0);
    expect(feeHeldCents(400, 4000, 0, true)).toBe(0);
  });
  it('the quote is the sum of per-ticket commissions', () => {
    expect(quoteTotal([{ commission_cents: 200 }, { commission_cents: 300 }, { nope: 1 }])).toBe(500);
  });
});

describe('netting', () => {
  it('organizer: owed is taken off the share, the rest carries forward', () => {
    expect(netOrganizerShare(5100, 1700, 300)).toEqual({ amount: 3400, netted: 1700, carry: 0 });
    expect(netOrganizerShare(1900, 5100, 100)).toEqual({ amount: 0, netted: 1900, carry: 3200 });
  });
  it('organizer: a credit is added, at most this order\'s fee', () => {
    expect(netOrganizerShare(1000, -150, 100)).toEqual({ amount: 1100, netted: -100, carry: -50 });
    expect(netOrganizerShare(1000, 0, 100)).toEqual({ amount: 1000, netted: 0, carry: 0 });
  });
  it('promoter: whole lines, oldest first, never more than the payout', () => {
    expect(nettedPayout(200, 0, [200])).toEqual({ cap: 200, netted: 200, applied: 1, amount: 0 });
    expect(nettedPayout(400, 100, [])).toEqual({ cap: 300, netted: 0, applied: 0, amount: 300 });
    expect(nettedPayout(500, 0, [300, 300])).toEqual({ cap: 500, netted: 300, applied: 1, amount: 200 });
    // Oldest first: a big old line blocks newer small ones (no reordering).
    expect(nettedPayout(250, 0, [300, 100])).toEqual({ cap: 250, netted: 0, applied: 0, amount: 250 });
  });
});

describe('checkout branching: destination vs split vs platform fee', () => {
  const base = { applicationFeeCents: 200, destination: 'acct_org' };
  const legacy = { application_fee_amount: 200, transfer_data: { destination: 'acct_org' } };
  it('no plan: exactly today\'s destination charge', () => {
    expect(paymentIntentData(null, base)).toEqual(legacy);
    expect(checkoutChargeMetadata(null)).toEqual({});
  });
  it('a manual / clawback plan charges exactly as today', () => {
    expect(paymentIntentData(plan({ method: 'clawback' }), base)).toEqual(legacy);
    expect(checkoutChargeMetadata(plan({ method: 'clawback' }))).toEqual({});
    expect(planChangesCharge(plan({ method: 'manual' }))).toBe(false);
  });
  it('platform fee: the commission rides in application_fee_amount', () => {
    const p = plan({ method: 'platform_fee', commission_fee_cents: 400 });
    expect(paymentIntentData(p, base)).toEqual({ application_fee_amount: 600, transfer_data: { destination: 'acct_org' } });
    expect(checkoutChargeMetadata(p)).toEqual({ exos_charge_model: 'destination', exos_commission_method: 'platform_fee', exos_commission_fee_cents: '400' });
    expect(planChangesCharge(p)).toBe(true);
    // No promoter on the order: nothing in the fee, charged as today.
    expect(paymentIntentData(plan({ method: 'platform_fee', commission_fee_cents: 0 }), base)).toEqual(legacy);
  });
  it('split: the charge stays on the platform with its transfer group', () => {
    const p = plan({ method: 'split_at_sale', charge_model: 'split', transfer_group: GROUP });
    expect(paymentIntentData(p, base)).toEqual({ transfer_group: GROUP });
    expect(checkoutChargeMetadata(p)).toEqual({ exos_charge_model: 'split', exos_commission_method: 'split_at_sale' });
  });
  it('parsePlan refuses plans that do not hold together', () => {
    expect(parsePlan({ method: 'split_at_sale', charge_model: 'split', transfer_group: GROUP, application_fee_cents: 200 })?.transfer_group).toBe(GROUP);
    expect(parsePlan({ method: 'split_at_sale', charge_model: 'split', transfer_group: null })).toBeNull();
    expect(parsePlan({ method: 'split_at_sale', charge_model: 'destination' })).toBeNull();
    expect(parsePlan({ method: 'manual', charge_model: 'split', transfer_group: GROUP })).toBeNull();
    expect(parsePlan({ method: 'manual', charge_model: 'destination', commission_fee_cents: 5 })).toBeNull();
    expect(parsePlan({ method: 'venmo', charge_model: 'destination' })).toBeNull();
    expect(parsePlan(null)).toBeNull();
    expect(parsePlan({ method: 'manual', charge_model: 'destination', transfer_group: GROUP })?.transfer_group).toBeNull();
  });
  it('the switches are on only when exactly "on"', () => {
    expect(commissionEnv(() => undefined)).toEqual({ splitAtSale: false, platformFeeCommissions: false });
    expect(needsCommissionPlan(commissionEnv((k) => (k === 'EXOS_SPLIT_AT_SALE' ? 'ON' : 'true')))).toBe(false);
    expect(commissionEnv((k) => (k === 'EXOS_PLATFORM_FEE_COMMISSIONS' ? 'on' : undefined))).toEqual({ splitAtSale: false, platformFeeCommissions: true });
  });
});

describe('webhook + refund branching', () => {
  it('reads the charge model from Checkout metadata (absent: destination)', () => {
    expect(chargeModelFromMetadata(undefined)).toBe('destination');
    expect(chargeModelFromMetadata({ exos_charge_model: 'split' })).toBe('split');
    expect(chargeModelFromMetadata({ exos_charge_model: 'destination', exos_commission_fee_cents: '400' })).toBe('destination');
  });
  it('the auto-refund keeps its parameters for destination orders', () => {
    const legacy = {
      payment_intent: 'pi_1', reason: 'requested_by_customer', reverse_transfer: true, refund_application_fee: true,
      metadata: { exos_session_id: 'cs_1', exos_auto: 'fulfillment_failed' },
    };
    expect(autoRefundParams('pi_1', 'cs_1')).toEqual(legacy);
    expect(autoRefundParams('pi_1', 'cs_1', 'destination')).toEqual(legacy);
  });
  it('a split order\'s auto-refund sends neither Connect flag', () => {
    const p = autoRefundParams('pi_1', 'cs_1', 'split');
    expect(p).not.toHaveProperty('reverse_transfer');
    expect(p).not.toHaveProperty('refund_application_fee');
    expect(p.metadata).toEqual({ exos_session_id: 'cs_1', exos_auto: 'fulfillment_failed' });
  });
  it('organizer refunds: default unchanged; split drops the flags; a fee with a commission always refunds the fee', () => {
    const req = { request_id: 'r1', amount_cents: 500, payment_intent: 'pi_1', session_id: 'cs_1', scope: 'tickets' };
    expect(organizerRefundParams(req, false)).toMatchObject({ reverse_transfer: true, refund_application_fee: true });
    expect(organizerRefundParams(req, true)).toMatchObject({ reverse_transfer: true, refund_application_fee: false });
    const split = organizerRefundParams(req, true, 'split');
    expect(split).not.toHaveProperty('reverse_transfer');
    expect(split).not.toHaveProperty('refund_application_fee');
    expect(split).toMatchObject({ amount: 500, payment_intent: 'pi_1' });
    expect(organizerRefundParams(req, true, 'commission_fee')).toMatchObject({ reverse_transfer: true, refund_application_fee: true });
    expect(organizerRefundParams(req, false, 'keep_fee')).toMatchObject({ reverse_transfer: true, refund_application_fee: false });
    expect(organizerRefundParams(req, false, 'reverse')).not.toHaveProperty('reverse_transfer');
    expect(refundFlags('split', { keepPlatformFee: true, commissionInFee: true })).toEqual({});
  });
  it('fee actuals: a commission in the fee is not Exos\'s net', () => {
    const charge = { id: 'ch_1', application_fee_amount: 600, balance_transaction: { id: 'txn_1', fee: 146 } };
    expect(feeActualsFromCharge(charge, 200).net_cents).toBe(454);
    expect(feeActualsFromCharge(charge, 200, 400).net_cents).toBe(54);
    expect(feeActualsFromCharge(charge, 200, 400).application_fee_cents).toBe(600);
  });
});

describe('organizer refund branching (exos_refund_charge_prepare)', () => {
  it('flags per mode: standard unchanged, fee with a commission back, kept once paid, none for split', () => {
    expect(refundFlagsForMode('standard', false)).toEqual({ reverse_transfer: true, refund_application_fee: true });
    expect(refundFlagsForMode('standard', true)).toEqual({ reverse_transfer: true, refund_application_fee: false });
    expect(refundFlagsForMode('commission_fee', true)).toEqual({ reverse_transfer: true, refund_application_fee: true });
    expect(refundFlagsForMode('keep_fee', false)).toEqual({ reverse_transfer: true, refund_application_fee: false });
    expect(refundFlagsForMode('split', false)).toEqual({});
    expect(refundFlagsForMode('reverse', true)).toEqual({});
  });
  it('a sent split share is reversed before the refund', () => {
    expect(refundPrepAction({ mode: 'reverse', reversal_id: 'rv1', org_transfer_id: 'tr_org', amount_cents: 950, status: 'planned' }))
      .toEqual({ action: 'reverse_then_refund', reversalId: 'rv1', transferId: 'tr_org', amountCents: 950, taken: false });
    expect(refundPrepAction({ mode: 'reverse', reversal_id: 'rv1', org_transfer_id: 'tr_org', amount_cents: 950, status: 'taken' }))
      .toMatchObject({ taken: true });
    expect(refundPrepAction({ mode: 'reverse', reversal_id: 'rv1', org_transfer_id: 'nope', amount_cents: 950 }).action).toBe('retry');
  });
  it('refused when Exos can\'t take it back; waits while a transfer is in flight; retries on a read error', () => {
    expect(refundPrepAction({ mode: 'refuse', error: 'Exos can take back only 0 cents' })).toEqual({ action: 'refuse', message: 'Exos can take back only 0 cents' });
    expect(refundPrepAction({ mode: 'busy' }).action).toBe('retry');
    expect(refundPrepAction(null).action).toBe('retry');
    expect(refundPrepAction({ mode: 'standard' })).toEqual({ action: 'refund', mode: 'standard' });
    expect(refundPrepAction({ mode: 'split' })).toEqual({ action: 'refund', mode: 'split' });
  });
  it('a retried reversal finds the one already made; one key per row', () => {
    expect(findSplitReversal('rv1', [{ id: 'trr_a', metadata: { exos_split_reversal_id: 'rv2' } }, { id: 'trr_b', metadata: { exos_split_reversal_id: 'rv1' } }])).toBe('trr_b');
    expect(findSplitReversal('rv1', [])).toBeNull();
    expect(splitReversalKey('rv1')).toBe('exos-ctr:rv1');
  });
});

describe('Exos-made transfers', () => {
  const claim = (o: Partial<CtClaim>): CtClaim => ({
    id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', lease_token: '11111111-1111-1111-1111-111111111111', purpose: 'send',
    kind: 'split_org', org_id: 'org-1', promoter_id: null, session_id: 'cs_1', payout_id: null, amount_cents: 3400,
    currency: 'USD', destination: 'acct_org', source_charge_id: 'ch_1', transfer_group: GROUP, stripe_transfer_id: null, ...o,
  });
  it('a split transfer comes from its order\'s charge, in its order\'s group', () => {
    const r = ctTransferParams(claim({}));
    expect(r).toEqual({ ok: true, params: {
      amount: 3400, currency: 'usd', destination: 'acct_org', transfer_group: GROUP, source_transaction: 'ch_1',
      metadata: { exos_ct_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', exos_kind: 'split_org', exos_org_id: 'org-1', exos_session_id: 'cs_1' },
    } });
    expect(ctTransferKey('x')).toBe('exos-ct:x');
  });
  it('a fee transfer comes from the platform balance', () => {
    const r = ctTransferParams(claim({ kind: 'fee_promoter', session_id: null, source_charge_id: null, promoter_id: 'p1', payout_id: 'po1',
      transfer_group: 'exos-fee-11111111-2222-3333-4444-555555555555', destination: 'acct_p', amount_cents: 300 }));
    expect(r.ok && r.params).toMatchObject({ amount: 300, destination: 'acct_p' });
    expect(r.ok && 'source_transaction' in r.params).toBe(false);
  });
  it('refuses rather than fixes', () => {
    expect(ctTransferParams(claim({ amount_cents: 0 }))).toEqual({ ok: false, error: 'nothing to send' });
    expect(ctTransferParams(claim({ destination: null }))).toEqual({ ok: false, error: 'no payout account' });
    expect(ctTransferParams(claim({ source_charge_id: null }))).toEqual({ ok: false, error: 'no source charge' });
    expect(ctTransferParams(claim({ transfer_group: 'other' }))).toEqual({ ok: false, error: 'bad transfer group' });
  });
  it('reconcile finds only this row\'s transfer in a shared order group', () => {
    const c = { id: 'ct-1', destination: 'acct_org' };
    expect(ctReconcileDecision(c, [
      { id: 'tr_promoter', destination: 'acct_p', metadata: { exos_ct_id: 'ct-2' } },
      { id: 'tr_org', destination: 'acct_org', metadata: { exos_ct_id: 'ct-1' } },
    ])).toBe('tr_org');
    expect(ctReconcileDecision(c, [{ id: 'tr_x', destination: 'acct_other', metadata: { exos_ct_id: 'ct-1' } }])).toBeNull();
    expect(ctReconcileDecision(c, [])).toBeNull();
  });
  it('money moves per kind only with its switch', () => {
    const on = { splitAtSale: true, platformFeeCommissions: false };
    expect(ctLive('split_org', on)).toBe(true);
    expect(ctLive('split_promoter', on)).toBe(true);
    expect(ctLive('fee_promoter', on)).toBe(false);
  });
  it('claim answers', () => {
    expect(ctClaimAction({ ok: false, error: 'needs_reconcile' })).toBe('reconcile_first');
    expect(ctClaimAction({ ok: false, error: 'busy' })).toEqual({ stop: 'busy' });
    expect(ctClaimAction({ ok: true, ...claim({}) })).toBe('proceed');
    expect(ctClaimAction({ ok: true, ...claim({ purpose: 'cancel', needs_reconcile: true }) })).toBe('reconcile_first');
    expect(ctClaimAction({ ok: true, ...claim({ lease_token: 'x' }) })).toEqual({ stop: 'no lease' });
  });
  it('the SQL lease and cancel wait are the wedge\'s, and one send fits the lease', () => {
    const sql = readFileSync('supabase/migrations/20261104190000_exos_commission_methods.sql', 'utf8');
    const fn = sql.slice(sql.indexOf('FUNCTION public.exos_ct_claim'), sql.indexOf('FUNCTION public.exos_ct_lease_ok'));
    expect(fn).toContain(`interval '${LEASE_MS / 60_000} minutes'`);
    expect(fn).toContain(`interval '${CANCEL_AFTER_MS / 60_000} minutes'`);
    // claim + lease check + one Stripe call + a durable mark, well inside the lease.
    expect(STRIPE_TIMEOUT_MS + DB_TIMEOUT_MS * (2 + DURABLE_TRIES)).toBeLessThan(LEASE_MS);
    expect(RUN_BUDGET_MS).toBeLessThan(150_000);
  });
});

describe('dashboard helpers', () => {
  it('most specific wins: promoter, event (locked, else override), org, manual', () => {
    expect(resolveMethod({})).toEqual({ method: 'manual', source: 'default' });
    expect(resolveMethod({ org: 'clawback' })).toEqual({ method: 'clawback', source: 'org' });
    expect(resolveMethod({ org: 'clawback', event: 'platform_fee' })).toEqual({ method: 'platform_fee', source: 'event' });
    expect(resolveMethod({ org: 'clawback', event: 'platform_fee', eventLocked: 'manual' }).method).toBe('manual');
    expect(resolveMethod({ org: 'clawback', eventLocked: 'manual', promoter: 'split_at_sale' })).toEqual({ method: 'split_at_sale', source: 'promoter' });
  });
  it('a sold event needs the future-sales-only confirmation to change', () => {
    expect(needsFutureOnlyConfirm({ sold: true, effective: 'manual' }, 'platform_fee')).toBe(true);
    expect(needsFutureOnlyConfirm({ sold: true, effective: 'manual' }, 'manual')).toBe(false);
    expect(needsFutureOnlyConfirm({ sold: false, effective: 'manual' }, 'split_at_sale')).toBe(false);
  });
  it('holdback 0 to 30 days', () => {
    expect(parseHoldbackDays('3')).toBe(3);
    expect(parseHoldbackDays(' 0 ')).toBe(0);
    expect(parseHoldbackDays('31')).toBeNull();
    expect(parseHoldbackDays('2.5')).toBeNull();
    expect(holdbackText(0)).toMatch(/as soon as the event ends/);
    expect(holdbackText(1)).toMatch(/1 day after/);
  });
  it('every method is explained, and the Exos-funded ones say who pays', () => {
    expect(METHODS).toHaveLength(4);
    for (const m of METHODS) expect(METHOD_INFO[m].short.length).toBeGreaterThan(20);
    expect(METHOD_INFO.platform_fee.how).toMatch(/includes the promoter's commission/);
    expect(METHOD_INFO.split_at_sale.needs.join(' ')).toMatch(/Express/);
    expect(METHOD_INFO.split_at_sale.how).toMatch(/disputes/);
  });
  it('balances and the netting line', () => {
    const b = normalizeBalances({ netting_alert_days: 30, promoters: [{ promoter_id: 'p', name: 'P', currency: 'usd', netting_owed_to_exos_cents: 400,
      netting_owed_to_you_cents: 200, netting_overdue: true, balance_cents: -600 }], organizer: [{ currency: 'usd', owed_to_exos_cents: 3200 }] });
    expect(b.promoters[0]).toMatchObject({ nettingOwedToExosCents: 400, nettingOwedToYouCents: 200, nettingOverdue: true, balanceCents: -600, heldCents: 0 });
    expect(b.organizer[0].owedToExosCents).toBe(3200);
    const money = (c: number) => `$${(c / 100).toFixed(2)}`;
    expect(nettingLine(b.promoters[0], money)).toBe('$2.00 owed back to you and $4.00 owed back to Exos for sales refunded after payout (overdue: no new commission to take it from).');
    expect(nettingLine({ nettingOwedToYouCents: 0, nettingOwedToExosCents: 0, nettingOverdue: false }, money)).toBeNull();
    expect(normalizeBalances(null).promoters).toEqual([]);
  });
});
