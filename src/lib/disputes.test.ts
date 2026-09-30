// Stripe dispute -> exos_record_dispute_event fields (supabase/functions/_shared/disputes.ts, mig 20261001101000).
import { describe, it, expect } from 'vitest';
import { disputeFields, disputeFeeCents, isDisputeId, stripeDisputeUrl } from '../../supabase/functions/_shared/disputes.ts';
import {
  disputeDueLabel, disputeReasonLabel, disputeStatusLabel, isOpenDispute, stripeDisputeLink, summarizeDisputes, type DisputeRow,
} from './disputesView';

const DISPUTE = {
  id: 'du_1Abc', object: 'dispute', amount: 5000, currency: 'USD', reason: 'fraudulent', status: 'needs_response',
  created: 1790000000, livemode: false, is_charge_refundable: false, network_reason_code: '10.4',
  charge: 'ch_1Abc', payment_intent: { id: 'pi_1Abc', object: 'payment_intent' },
  metadata: { note: 'x' },
  evidence: { customer_email_address: 'buyer@x.com', customer_name: 'Buyer Name', billing_address: '1 Main St', customer_purchase_ip: '1.2.3.4' },
  evidence_details: { due_by: 1792108799, has_evidence: false, past_due: false, submission_count: 0 },
  balance_transactions: [{ id: 'txn_1', amount: -5000, fee: 1500, net: -6500, type: 'adjustment', reporting_category: 'dispute', created: 1790000000, description: 'buyer@x.com' }],
  payment_method_details: { type: 'card', card: { brand: 'visa' } },
};

describe('disputeFields', () => {
  it('maps a Stripe dispute to the recorder arguments', () => {
    const f = disputeFields(DISPUTE);
    expect(f).toMatchObject({
      dispute_id: 'du_1Abc', charge_id: 'ch_1Abc', payment_intent: 'pi_1Abc', amount_cents: 5000, currency: 'usd',
      reason: 'fraudulent', status: 'needs_response', fee_cents: 1500, evidence_due_by: '2026-10-15T23:59:59.000Z',
      evidence_submitted: false, livemode: false,
    });
  });

  it('raw keeps no evidence, metadata or buyer data', () => {
    const { raw } = disputeFields(DISPUTE);
    const text = JSON.stringify(raw);
    expect(raw).not.toHaveProperty('evidence');
    expect(raw).not.toHaveProperty('metadata');
    expect(text).not.toContain('buyer@x.com');
    expect(text).not.toContain('Buyer Name');
    expect(text).not.toContain('1.2.3.4');
    expect(raw).toMatchObject({ id: 'du_1Abc', status: 'needs_response', card_brand: 'visa', network_reason_code: '10.4' });
    expect((raw.balance_transactions as unknown[])[0]).toEqual({
      id: 'txn_1', amount: -5000, fee: 1500, net: -6500, type: 'adjustment', reporting_category: 'dispute', created: 1790000000,
    });
  });

  it('evidence counts as submitted once Stripe has a submission or the dispute is under review', () => {
    expect(disputeFields({ ...DISPUTE, evidence_details: { ...DISPUTE.evidence_details, submission_count: 1 } }).evidence_submitted).toBe(true);
    expect(disputeFields({ ...DISPUTE, status: 'under_review' }).evidence_submitted).toBe(true);
    expect(disputeFields({ ...DISPUTE, evidence_details: { ...DISPUTE.evidence_details, has_evidence: true } }).evidence_submitted).toBe(false);
  });

  it('copes with a sparse object (no balance transactions, no deadline, expanded charge)', () => {
    const f = disputeFields({ id: 'dp_9', status: 'WON', charge: { id: 'ch_9' } });
    expect(f).toMatchObject({ dispute_id: 'dp_9', status: 'won', charge_id: 'ch_9', payment_intent: null, fee_cents: null,
      evidence_due_by: null, amount_cents: null, currency: 'usd', livemode: null });
  });

  it('refuses a malformed id or status', () => {
    expect(() => disputeFields({ ...DISPUTE, id: 'evil"id' })).toThrow('dispute id');
    expect(() => disputeFields({ ...DISPUTE, status: 'Bad Status!' })).toThrow('status');
  });
});

describe('dispute helpers', () => {
  it('fee: sum of balance-transaction fees, never below zero', () => {
    expect(disputeFeeCents([{ fee: 1500 }, { fee: 0 }])).toBe(1500);
    expect(disputeFeeCents([{ fee: 1500 }, { fee: -1500 }])).toBe(0);
    expect(disputeFeeCents([{ fee: -200 }])).toBe(0);
    expect(disputeFeeCents([])).toBeNull();
    expect(disputeFeeCents(null)).toBeNull();
  });
  it('ids and dashboard links', () => {
    expect(isDisputeId('du_1Abc')).toBe(true);
    expect(isDisputeId('dp_1Abc')).toBe(true);
    expect(isDisputeId('ch_1Abc')).toBe(false);
    expect(stripeDisputeUrl('du_1Abc')).toBe('https://dashboard.stripe.com/disputes/du_1Abc');
    expect(stripeDisputeUrl('du_1Abc', false)).toBe('https://dashboard.stripe.com/test/disputes/du_1Abc');
    expect(stripeDisputeUrl('javascript:x')).toBeNull();
  });
});

// The organizer Disputes block's helpers (src/lib/disputesView.ts).

const row = (over: Partial<DisputeRow>): DisputeRow => ({
  id: 'r1', event_id: null, session_id: 'cs_1', dispute_id: 'du_1', amount_cents: 5000, fee_cents: 1500, currency: 'usd',
  reason: 'fraudulent', status: 'needs_response', evidence_due_by: '2026-10-15T23:59:59Z', evidence_submitted: false,
  livemode: true, created_at: '2026-09-30T00:00:00Z', closed_at: null, recovery_status: 'none', recovery_candidate_cents: null, ...over,
});

describe('disputes view', () => {
  it('labels', () => {
    expect(disputeStatusLabel('needs_response')).toBe('Needs response');
    expect(disputeStatusLabel('warning_needs_response')).toBe('Inquiry: needs response');
    expect(disputeStatusLabel('something_new')).toBe('something new');
    expect(disputeReasonLabel('product_not_received')).toBe('Product not received');
    expect(disputeReasonLabel(null)).toBe('—');
    expect(isOpenDispute('under_review')).toBe(true);
    expect(isOpenDispute('warning_closed')).toBe(false);
  });
  it('due date: days left, overdue, nothing once submitted or closed', () => {
    const now = new Date('2026-10-10T12:00:00Z');
    expect(disputeDueLabel(row({}), now)).toBe('Due Oct 15 (in 5 days)');
    expect(disputeDueLabel(row({ evidence_due_by: '2026-10-10T20:00:00Z' }), now)).toBe('Due Oct 10 (today)');
    expect(disputeDueLabel(row({ evidence_due_by: '2026-10-01T00:00:00Z' }), now)).toBe('Overdue since Oct 1');
    expect(disputeDueLabel(row({ evidence_submitted: true }), now)).toBe('');
    expect(disputeDueLabel(row({ status: 'lost' }), now)).toBe('');
  });
  it('Stripe link and summary', () => {
    expect(stripeDisputeLink(row({ livemode: false }))).toBe('https://dashboard.stripe.com/test/disputes/du_1');
    expect(stripeDisputeLink(row({ dispute_id: 'x"y' }))).toBeNull();
    expect(summarizeDisputes([row({}), row({ status: 'lost', amount_cents: 2500 }), row({ status: 'won', fee_cents: null })])).toEqual({
      open: 1, openCents: 5000, lost: 1, lostCents: 2500, feesCents: 3000, won: 1,
    });
  });
});
