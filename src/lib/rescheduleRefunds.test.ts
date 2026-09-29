// Refunds when the date changes (mig 20260929150000): the pure rules shared by
// the SPA and exos-refund (supabase/functions/_shared/reschedule-refund.ts),
// and the event-rescheduled mail (supabase/functions/_shared/mail-templates.ts).
// The SQL mirror of the first two is tested in tests/exos/test_reschedule_refunds.sql
// (R2 uses the same cases).
import { describe, it, expect } from 'vitest';
import {
  qualifiesAsDateChange,
  defaultRefundDeadline,
  deadlineProblem,
  rescheduleEligibility,
  rescheduleKind,
  rescheduleRefundAmount,
  reasonText,
  localDay,
  RESCHEDULE_TOKEN_RE,
  type RescheduleTicketFacts,
} from '../../supabase/functions/_shared/reschedule-refund.ts';
import { renderTemplate } from '../../supabase/functions/_shared/mail-templates.ts';

describe('qualifiesAsDateChange', () => {
  const NY = 'America/New_York';
  it('same local day within 3 hours does not qualify', () => {
    expect(qualifiesAsDateChange('2026-10-10T23:00Z', '2026-10-11T01:00Z', NY)).toBe(false);
    expect(qualifiesAsDateChange('2026-10-10T23:00Z', '2026-10-11T02:00Z', NY)).toBe(false); // exactly 3h
  });
  it('more than 3 hours qualifies', () => {
    expect(qualifiesAsDateChange('2026-10-10T23:00Z', '2026-10-11T02:30Z', NY)).toBe(true);
    expect(qualifiesAsDateChange('2026-10-11T02:30Z', '2026-10-10T23:00Z', NY)).toBe(true); // earlier too
  });
  it('another day in the event zone qualifies, even by an hour', () => {
    // 11:30pm -> 12:30am New York time
    expect(qualifiesAsDateChange('2026-10-11T03:30Z', '2026-10-11T04:30Z', NY)).toBe(true);
    expect(qualifiesAsDateChange('2026-10-11T03:30Z', '2026-10-11T04:30Z', 'UTC')).toBe(false);
    expect(qualifiesAsDateChange('2026-10-11T03:30Z', '2026-10-11T04:30Z', 'Not/AZone')).toBe(false); // UTC fallback
    expect(localDay(new Date('2026-10-11T03:30Z'), NY)).toBe('2026-10-10');
  });
  it('no old or new date: nothing to compare', () => {
    expect(qualifiesAsDateChange(null, '2026-10-11T04:30Z', NY)).toBe(false);
    expect(qualifiesAsDateChange('2026-10-11T04:30Z', 'garbage', NY)).toBe(false);
  });
});

describe('defaultRefundDeadline', () => {
  it('is the earlier of change + 14 days and new start − 24 h', () => {
    expect(defaultRefundDeadline('2026-10-01T12:00Z', '2026-11-01T12:00Z')?.toISOString()).toBe('2026-10-15T12:00:00.000Z');
    expect(defaultRefundDeadline('2026-10-01T12:00Z', '2026-10-05T12:00Z')?.toISOString()).toBe('2026-10-04T12:00:00.000Z');
  });
  it('runs until the start when that is under a day away, and is null for a past start', () => {
    expect(defaultRefundDeadline('2026-10-01T12:00Z', '2026-10-02T06:00Z')?.toISOString()).toBe('2026-10-02T06:00:00.000Z');
    expect(defaultRefundDeadline('2026-10-01T12:00Z', '2026-10-01T11:00Z')).toBeNull();
    expect(defaultRefundDeadline('2026-10-01T12:00Z', null)).toBeNull();
  });
  it('deadlineProblem refuses past and after-the-start deadlines', () => {
    const now = new Date('2026-10-01T12:00Z');
    const start = new Date('2026-10-20T00:00Z');
    expect(deadlineProblem(new Date('2026-10-10T00:00Z'), start, now)).toBeNull();
    expect(deadlineProblem(new Date('2026-09-30T00:00Z'), start, now)).toMatch(/future/);
    expect(deadlineProblem(new Date('2026-10-21T00:00Z'), start, now)).toMatch(/after the new start/);
    expect(deadlineProblem(null, start, now)).toMatch(/Pick/);
  });
});

describe('rescheduleEligibility', () => {
  const now = new Date('2026-10-05T00:00Z');
  const base: RescheduleTicketFacts = {
    reschedule: { createdAt: new Date('2026-10-01T00:00Z'), refundsOffered: true, refundDeadline: new Date('2026-10-15T00:00Z') },
    eventCancelled: false,
    ticketStatus: 'active',
    checkedIn: false,
    boughtAt: new Date('2026-09-20T00:00Z'),
    channelSource: 'stripe',
    paidViaExos: true,
    pricePaid: 30,
    isTable: false,
    inTransfer: false,
    requestStatus: null,
    shareLeftCents: 3000,
    orderLeftCents: 3000,
    hasCardPayment: true,
    requesterIsPayer: true,
    requesterIsHolder: true,
  };
  const why = (over: Partial<RescheduleTicketFacts>) => rescheduleEligibility({ ...base, ...over }, now).reason;

  it('a paid, active ticket asked for by its buyer before the deadline is refundable', () => {
    expect(rescheduleEligibility(base, now)).toEqual({ ok: true, kind: 'refund', reason: null });
  });
  it('transferred: the original buyer may, the current holder may not', () => {
    expect(rescheduleEligibility({ ...base, requesterIsHolder: false }, now).ok).toBe(true);
    expect(why({ requesterIsPayer: false })).toBe('not-buyer');
  });
  it('refuses the listed cases', () => {
    expect(why({ reschedule: null })).toBe('no-reschedule');
    expect(why({ reschedule: { ...base.reschedule!, refundsOffered: false } })).toBe('refunds-not-offered');
    expect(why({ eventCancelled: true })).toBe('event-cancelled');
    expect(why({ reschedule: { ...base.reschedule!, refundDeadline: new Date('2026-10-05T00:00Z') } })).toBe('deadline-passed');
    expect(why({ ticketStatus: 'used' })).toBe('checked-in');
    expect(why({ checkedIn: true })).toBe('checked-in');
    expect(why({ ticketStatus: 'voided' })).toBe('voided');
    expect(why({ boughtAt: new Date('2026-10-02T00:00Z') })).toBe('bought-after-change');
    expect(why({ channelSource: 'stubhub', paidViaExos: false })).toBe('marketplace');
    expect(why({ channelSource: 'boxoffice', paidViaExos: false, pricePaid: 25 })).toBe('not-exos-paid');
    expect(why({ inTransfer: true })).toBe('in-transfer');
    expect(why({ requestStatus: 'pending' })).toBe('in-progress');
    expect(why({ requestStatus: 'succeeded' })).toBe('refunded');
    expect(why({ shareLeftCents: 0 })).toBe('refunded');
    expect(why({ hasCardPayment: false })).toBe('no-card-payment');
  });
  it('free and comp tickets are released by their holder, not refunded', () => {
    const comp = { ...base, channelSource: 'comp', paidViaExos: false, pricePaid: 0 };
    expect(rescheduleEligibility(comp, now)).toEqual({ ok: true, kind: 'release', reason: null });
    expect(rescheduleEligibility({ ...comp, requesterIsHolder: false }, now).reason).toBe('not-holder');
    expect(rescheduleEligibility({ ...comp, isTable: true }, now).reason).toBe('table');
    expect(rescheduleKind({ channelSource: 'stripe', paidViaExos: false, pricePaid: 0 })).toBe('release');
  });
  it('a failed earlier attempt can be retried', () => {
    expect(rescheduleEligibility({ ...base, requestStatus: 'failed' }, now).ok).toBe(true);
  });
});

describe('rescheduleRefundAmount', () => {
  it('is the ticket share while other tickets of the order have money left', () => {
    expect(rescheduleRefundAmount(3000, 7000, 3000)).toBe(3000);
  });
  it('takes the add-ons with the last ticket', () => {
    expect(rescheduleRefundAmount(3000, 4000, 0)).toBe(4000);
  });
  it('never more than the order has left', () => {
    expect(rescheduleRefundAmount(3000, 2500, 3000)).toBe(2500);
    expect(rescheduleRefundAmount(3000, -5, 0)).toBe(0);
  });
});

describe('reasonText / token', () => {
  it('explains every reason in plain words, with a fallback', () => {
    expect(reasonText('not-buyer')).toMatch(/Someone else paid/);
    expect(reasonText('marketplace')).toMatch(/marketplace/);
    expect(reasonText('constructor')).toBe("This ticket can't be refunded right now.");
    expect(reasonText(null)).toBe("This ticket can't be refunded right now.");
  });
  it('tokens are 64 lowercase hex', () => {
    expect(RESCHEDULE_TOKEN_RE.test('a'.repeat(64))).toBe(true);
    expect(RESCHEDULE_TOKEN_RE.test('A'.repeat(64))).toBe(false);
    expect(RESCHEDULE_TOKEN_RE.test('a'.repeat(63))).toBe(false);
  });
});

describe('event-rescheduled mail', () => {
  const APP = 'https://exos.example/bridge';
  const EV = '11111111-1111-4111-8111-111111111111';
  const T1 = '44444444-4444-4444-8444-444444444444';
  const TOK = 'b'.repeat(64);
  const payload = (over: Record<string, unknown> = {}) => ({
    event: {
      id: EV, name: 'Show <One>', starts_at: '2026-10-20T23:00:00+00:00', doors_at: '2026-10-20T22:00:00+00:00',
      timezone: 'America/New_York', venue_name: 'Hall & Annex', org_name: 'Org <7f>',
    },
    old_starts_at: '2026-10-10T23:00:00+00:00', new_starts_at: '2026-10-20T23:00:00+00:00',
    reason: 'Venue <flood>', refunds_offered: true, refund_deadline: '2026-10-19T23:00:00+00:00',
    refunds: [{ ticket_id: T1, tier_name: 'GA <early>', token: TOK, amount_cents: 3000, currency: 'usd' }],
    releases: [], more_links: 0, tickets: 1, marketplace: 0, not_buyer: 0, other_paid: 0, marketing: false,
    ...over,
  });
  const render = (over: Record<string, unknown> = {}) => {
    const r = renderTemplate('event-rescheduled', payload(over), APP);
    if ('error' in r) throw new Error(r.error);
    return r;
  };

  it('old and new date in the event zone, escaped organizer text', () => {
    const r = render();
    expect(r.subject).toBe('New date: Show <One>');
    expect(r.html).toContain('Was: <s>Saturday, October 10 at 7:00 PM EDT</s>');
    expect(r.html).toContain('Now: <strong>Tuesday, October 20 at 7:00 PM EDT</strong>');
    expect(r.html).toContain('Doors open Tuesday, October 20 at 6:00 PM EDT');
    expect(r.html).toContain('Venue &lt;flood&gt;');
    expect(r.html).not.toMatch(/<One>|<flood>|<early>|<7f>/);
  });
  it('refund link per ticket with the deadline', () => {
    const r = render();
    expect(r.html).toContain(`href="${APP}/refund?t=${TOK}">Get a refund: GA &lt;early&gt; ($30.00)</a>`);
    expect(r.html).toContain('until <strong>Monday, October 19 at 7:00 PM EDT</strong>');
    expect(r.html).toContain('goes back to the card you paid with');
    for (const h of [...r.html.matchAll(/href="([^"]*)"/g)].map((m) => m[1])) expect(h.startsWith(`${APP}/`)).toBe(true);
  });
  it('release link for a free ticket', () => {
    const r = render({ refunds: [], releases: [{ ticket_id: T1, tier_name: 'Guest list', token: TOK }] });
    expect(r.html).toContain(`href="${APP}/refund?t=${TOK}">Release my ticket: Guest list</a>`);
    expect(r.html).not.toContain('Get a refund');
  });
  it('no refunds offered: just the new date', () => {
    const r = render({ refunds_offered: false, refunds: [], refund_deadline: null });
    expect(r.html).toContain("There's nothing you need to do.");
    expect(r.html).not.toContain('/refund?t=');
  });
  it('marketplace buyers go to the marketplace; a holder someone else paid for is told why', () => {
    const r = render({ refunds: [], marketplace: 2, not_buyer: 1 });
    expect(r.html).toContain('You bought 2 tickets on a resale marketplace. Refunds for those go through the marketplace');
    expect(r.html).toContain('Someone else paid for a ticket you hold');
    expect(r.html).not.toContain('/refund?t=');
  });
  it('refuses a link without a valid token', () => {
    const bad = renderTemplate('event-rescheduled', payload({ refunds: [{ ticket_id: T1, token: '"><x', amount_cents: 1 }] }), APP);
    expect(bad).toEqual({ ok: false, error: 'event-rescheduled: token missing' });
  });
});
