// Payload-rendered mail (supabase/functions/_shared/mail-templates.ts, mig 20260929071000).
import { describe, it, expect } from 'vitest';
import {
  renderTemplate, escapeHtml, formatMoney, formatWhen, formatDate, plainSubject, PAYLOAD_TEMPLATES,
} from '../../supabase/functions/_shared/mail-templates.ts';
import { renderMail } from '../../supabase/functions/_shared/mail-render.ts';

const APP = 'https://exos.example/bridge';
const EV = '11111111-1111-4111-8111-111111111111';
const EV2 = '22222222-2222-4222-8222-222222222222';
const ORG = '33333333-3333-4333-8333-333333333333';
const TIER = '44444444-4444-4444-8444-444444444444';
const TOKEN = 'a'.repeat(64);
const EVIL = `<script>alert("x")</script> & 'co'`;
const STRIPE_DISPUTE = /^https:\/\/dashboard\.stripe\.com\/(test\/)?disputes\/(dp|du)_[A-Za-z0-9]+$/;

const event = (over: Record<string, unknown> = {}) => ({
  id: EV, name: 'Show <One> & "Friends"', starts_at: '2026-10-02T00:00:00+00:00', timezone: 'America/New_York',
  doors_at: '2026-10-01T23:00:00+00:00', venue_name: 'Hall & Annex', venue_location: 'Brooklyn, NY',
  org_id: ORG, org_name: 'Org <7f>', ...over,
});
const org = { id: ORG, name: 'Org <7f> & Co' };

// One valid payload per template, as the SQL queues it.
const PAYLOADS: Record<string, Record<string, unknown>> = {
  'event-cancelled': { event: event(), reason: EVIL, refund: { status: 'refunded', paid_cents: 5000, refunded_cents: 5000, currency: 'usd' }, marketing: false },
  'event-updated': { event: event(), marketing: false },
  'event-rescheduled': {
    event: event(), reschedule_id: EV2, old_starts_at: '2026-09-30T23:00:00+00:00', new_starts_at: '2026-10-02T00:00:00+00:00',
    reason: EVIL, refunds_offered: true, refund_deadline: '2026-10-01T00:00:00+00:00',
    refunds: [{ ticket_id: TIER, tier_name: 'GA <early>', token: TOKEN, amount_cents: 3000, currency: 'usd' }],
    releases: [], more_links: 0, tickets: 1, marketplace: 1, not_buyer: 0, other_paid: 0, marketing: false,
  },
  'refund-issued': { event: event(), amount_cents: 1000, currency: 'usd', order_ref: 'cs_<x>', paid_cents: 3000, refunded_total_cents: 1000, partial: true, marketing: false },
  'post-event': {
    event: event(), org, following: false, marketing: true, unsubscribe_token: TOKEN,
    next_events: [{ id: EV2, name: 'Next <Show>', starts_at: '2026-11-01T01:00:00+00:00', timezone: 'America/New_York', venue_name: 'Club' }],
  },
  'event-published': { event: event(), marketing: false },
  'inventory-low': { event: event(), tier: { id: TIER, name: 'GA <early>', capacity: 10, sold: 9, remaining: 1 }, marketing: false },
  'inventory-sold-out': { event: event(), tier: { id: TIER, name: 'GA', capacity: 10, sold: 10, remaining: 0 }, marketing: false },
  'fixed-block-released': {
    event: event(), platform: 'DICE <x>', released_at: '2026-10-01T00:00:00+00:00', reason: 'scheduled',
    tiers: [
      { tier_id: TIER, name: 'GA <early>', kind: 'standard', party_size: null, block: 120, sold: 23, pending: 2, returned: 95 },
      { tier_id: EV2, name: 'Booth', kind: 'table', party_size: 6, block: 4, sold: 3, pending: 0, returned: 1 },
    ],
    total_returned: 96, total_pending: 2, marketing: false,
  },
  'payout-sent': { org, amount_cents: 123456, currency: 'usd', period: 'Sep 1-15, 2026', reference: 'po_<1>', marketing: false },
  'payout-pending': { org, amount_cents: 50000, currency: 'eur', period: 'Sep 16-30', reference: null, marketing: false },
  'fee-free-ending': { org, fee_free_until: '2026-10-12T00:00:00+00:00', stage: '14d', days_left: 14, fee_bps: 300, marketing: false },
  'org-welcome': { org, fee_free_until: '2027-03-28T00:00:00+00:00', has_event: false, marketing: false },
  'signup-confirm': { org, form_title: 'Join <the> list', token: TOKEN, email_requested: true, sms_requested: true, marketing: false },
  'org-first-event': { org, has_event: false, marketing: true, unsubscribe_token: TOKEN },
  'org-connect-stripe': { org, has_event: true, marketing: true, unsubscribe_token: TOKEN },
  'org-sales-digest': {
    org, from: '2026-09-27T00:00:00+00:00', to: '2026-09-28T00:00:00+00:00', marketing: true, unsubscribe_token: TOKEN,
    events: [{ id: EV, name: 'Show <One>', currency: 'usd', orders: 1, tickets: 2, gross_cents: 16000 }],
    totals: [{ currency: 'usd', orders: 1, tickets: 2, gross_cents: 16000 }],
  },
  'dispute-opened': {
    org, event: event(), dispute_id: 'du_1Abc', livemode: false, amount_cents: 5000, fee_cents: 1500, currency: 'usd',
    reason: 'fraudulent', status: 'needs_response', evidence_due_by: '2026-10-15T23:59:59+00:00', evidence_submitted: false,
    recovery_status: 'none', recovery_candidate_cents: null, marketing: false,
  },
  'dispute-won': {
    org, event: event(), dispute_id: 'du_1Abc', livemode: true, amount_cents: 5000, fee_cents: 1500, currency: 'usd',
    reason: 'product_not_received', status: 'won', evidence_due_by: null, evidence_submitted: true,
    recovery_status: 'none', recovery_candidate_cents: null, marketing: false,
  },
  'dispute-lost': {
    org, event: event(), dispute_id: 'du_1Abc', livemode: true, amount_cents: 5000, fee_cents: 1500, currency: 'usd',
    reason: 'fraudulent', status: 'lost', evidence_due_by: null, evidence_submitted: false,
    recovery_status: 'not_recovered', recovery_candidate_cents: 6500, marketing: false,
  },
  'org-weekly-summary': {
    org, from: '2026-09-21T00:00:00+00:00', to: '2026-09-28T00:00:00+00:00', marketing: true, unsubscribe_token: TOKEN,
    events: [{ id: EV, name: 'Show', currency: 'usd', orders: 3, tickets: 5, gross_cents: 40000 }],
    totals: [{ currency: 'usd', orders: 3, tickets: 5, gross_cents: 40000 }],
    checkins: 12, upcoming: [{ id: EV2, name: 'Next <Show>', starts_at: '2026-10-05T00:00:00+00:00', timezone: 'UTC', sold: 40, capacity: 100 }],
  },
  // As exos_send_channel_reports queues it (mig 20261029120000).
  'org-channel-report': {
    org, from: '2026-10-19T00:00:00+00:00', to: '2026-10-26T00:00:00+00:00', iso_week: '2026-W43',
    marketing: true, unsubscribe_token: TOKEN, more_events: 2,
    events: [{
      id: EV, name: 'Show <One>', starts_at: '2026-11-01T01:00:00+00:00', timezone: 'America/New_York', currency: 'usd', capacity: 200,
      channels: [
        { channel: 'instagram', label: 'Instagram', group: 'exos', kind: 'sale', currency: 'usd', fees: 'reported', dated: true,
          week: [2, 5000, 100, 150, 4750], to_date: [3, 7500, 150, 225, 7125] },
        { channel: 'eventbrite', label: 'Eventbrite', group: 'eventbrite', kind: 'sale', currency: 'usd', fees: 'not_reported', dated: true,
          week: [1, null, null, 0, null], to_date: [4, null, null, 0, null] },
        { channel: 'luma', label: 'Luma', group: 'luma', kind: 'sale', currency: 'usd', fees: 'not_reported', dated: false,
          week: null, to_date: [5, null, null, 0, null] },
        { channel: 'promoter-x', label: 'Promoters', detail: 'x', group: 'exos', kind: 'sale', currency: 'usd', fees: 'none', dated: true,
          week: [0, 0, 0, 0, 0], to_date: [1, 0, 0, 0, 0] },
        { channel: 'promoter-dj-kay', label: 'Promoters', detail: 'dj-kay', group: 'exos', kind: 'sale', currency: 'usd', fees: 'none', dated: true,
          week: [0, 0, 0, 0, 0], to_date: [1, 0, 0, 0, 0] },
        // utm_source "evil.com", "+1 212 555 0100", "<b>x</b>" as the SQL hands them over (C8).
        { channel: 'evil', label: 'Other', detail: 'evil', group: 'exos', kind: 'sale', currency: 'usd', fees: 'none', dated: true,
          week: [1, 0, 0, 0, 0], to_date: [1, 0, 0, 0, 0] },
        { channel: '1-212-555-0100', label: 'Other', detail: '1-212-555-0100', group: 'exos', kind: 'sale', currency: 'usd', fees: 'none', dated: true,
          week: [1, 0, 0, 0, 0], to_date: [1, 0, 0, 0, 0] },
        { channel: 'b-x-b', label: 'Other', detail: 'b-x-b', group: 'exos', kind: 'sale', currency: 'usd', fees: 'none', dated: true,
          week: [1, 0, 0, 0, 0], to_date: [2, 0, 0, 0, 0] },
        { channel: 'comp', label: 'Comps', group: 'comp', kind: 'comp', currency: 'usd', fees: 'none', dated: true,
          week: [2, null, 0, 0, null], to_date: [6, null, 0, 0, null] },
        { channel: 'import-posh', label: 'Imported list (Posh)', detail: null, group: 'imported', kind: 'attendee', currency: 'usd', fees: 'none', dated: true,
          week: [0, null, null, null, null], to_date: [3, null, null, null, null] },
      ],
      totals: {
        week: [{ currency: 'usd', tickets: 3, gross_cents: 5000, fee_cents: 100, exos_fee_cents: 150, net_cents: 4750, gross_not_reported: 1, net_not_reported: 1 }],
        to_date: [{ currency: 'usd', tickets: 13, gross_cents: 7500, fee_cents: 150, exos_fee_cents: 225, net_cents: 7125, gross_not_reported: 9, net_not_reported: 9 }],
      },
    }],
    totals: {
      week: [{ currency: 'usd', tickets: 3, gross_cents: 5000, fee_cents: 100, exos_fee_cents: 150, net_cents: 4750, gross_not_reported: 1, net_not_reported: 1 }],
      to_date: [{ currency: 'usd', tickets: 13, gross_cents: 7500, fee_cents: 150, exos_fee_cents: 225, net_cents: 7125, gross_not_reported: 9, net_not_reported: 9 }],
    },
  },
  'offer-sent': {
    org, token: TOKEN, marketing: false,
    offer: { id: EV2, title: 'Night <One>', artist_name: 'Band <x>', dates: ['2026-11-19'], venue: 'Club <1>', currency: 'USD',
      terms: { deal_type: 'versus', guarantee_cents: 100000, percentage: 85, bonuses: [{ sold: 400, amount_cents: 25000 }], deposit_cents: 50000 },
      expires_at: '2026-11-07T15:00:00+00:00', agent_name: 'Ann <7f>' },
  },
  'settlement-finalized': { org, event: event(), token: TOKEN, marketing: false },
  'ticket-counts': {
    org, recipient_name: 'Ann <7f>', optout_token: TOKEN, marketing: false,
    counts: { event: event(), currency: 'USD', tiers: [{ name: 'GA <early>', paid: 300, comps: 10, gross_cents: 600000 }], paid_sold: 300,
      comps: 10, sold_last_24h: 12, gross_cents: 600000, capacity: 500, attendance_percent: 64, sold_elsewhere: [{ currency: 'USD', sold: 20, gross_cents: 40000 }] },
  },
};

function ok(template: string, payload: unknown = PAYLOADS[template], app: string | null = APP) {
  const r = renderTemplate(template, payload, app);
  if ("error" in r) throw new Error(`${template}: ${r.error}`);
  return r;
}

describe('helpers', () => {
  it('escapes the five HTML specials', () => {
    expect(escapeHtml(`<a href="x">'&'</a>`)).toBe('&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;');
    expect(escapeHtml(null)).toBe('');
  });
  it('formats all-in money by currency', () => {
    expect(formatMoney(123456, 'usd')).toBe('$1,234.56');
    expect(formatMoney(5000, 'EUR')).toBe('€50.00');
    expect(formatMoney(100, 'zzz1')).toBe('1.00 ZZZ1');
  });
  it('formats times in the event zone, falling back to UTC', () => {
    expect(formatWhen('2026-10-02T00:00:00Z', 'America/New_York')).toBe('Thursday, October 1 at 8:00 PM EDT');
    expect(formatWhen('2026-10-02T00:00:00Z', 'Not/AZone')).toBe('Friday, October 2 at 12:00 AM UTC');
    expect(formatWhen('garbage', 'UTC')).toBe('');
    expect(formatDate('2026-10-12T00:00:00Z')).toBe('October 12, 2026');
  });
  it('keeps subjects to one plain line', () => {
    expect(plainSubject('Hi\r\nBcc: x@y.com\t there')).toBe('Hi Bcc: x@y.com there');
    expect(plainSubject('x'.repeat(300))).toHaveLength(200);
  });
});

describe('renderTemplate', () => {
  it('has a payload and a renderer for every template the SQL queues', () => {
    expect(PAYLOAD_TEMPLATES.sort()).toEqual(Object.keys(PAYLOADS).sort());
  });

  for (const template of Object.keys(PAYLOADS)) {
    it(`${template}: renders, escapes, links only into the app`, () => {
      const r = ok(template);
      expect(r.subject.length).toBeGreaterThan(0);
      expect(r.subject).not.toMatch(/[\r\n]|&lt;|&amp;/);         // plain text, raw names
      expect(r.html).not.toMatch(/<script|<One>|<7f>|<early>|<Show>|<1>|<x>/); // nothing unescaped
      expect(r.html).not.toContain('{{app_url}}');
      const hrefs = [...r.html.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
      expect(hrefs.length).toBeGreaterThan(0);
      // The one link out of the app: Stripe's page for a dispute (dispute mails only).
      for (const h of hrefs) expect(h.startsWith(`${APP}/`) || (template.startsWith('dispute-') && STRIPE_DISPUTE.test(h))).toBe(true);
    });
  }

  it('event-cancelled: raw reason escaped, refund status in words', () => {
    const r = ok('event-cancelled');
    expect(r.subject).toBe('Cancelled: Show <One> & "Friends"');
    expect(r.html).toContain('Show &lt;One&gt; &amp; &quot;Friends&quot;');
    expect(r.html).toContain('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;co&#39;');
    expect(r.html).toContain('Your refund of $50.00 has been issued');
    expect(r.html).toContain('Thursday, October 1 at 8:00 PM EDT · Hall &amp; Annex, Brooklyn, NY');
    const status = (s: string, extra: Record<string, unknown> = {}) =>
      ok('event-cancelled', { ...PAYLOADS['event-cancelled'], refund: { status: s, paid_cents: 3000, refunded_cents: 1000, currency: 'usd', ...extra } }).html;
    expect(status('partial')).toContain('$10.00 of the $30.00 you paid has been refunded so far');
    expect(status('processing')).toContain('Your refund of $30.00 is being processed');
    expect(status('pending')).toContain('You paid $30.00. The organizer is refunding orders');
    expect(status('none')).toContain('This ticket was free');
    expect(status('not_buyer')).toContain('person who bought the tickets');
    expect(status('weird')).toContain('This ticket was free');
    expect(ok('event-cancelled', { ...PAYLOADS['event-cancelled'], reason: null }).html).not.toContain('From the organizer');
  });

  it('refund-issued: amount, partial progress, order reference', () => {
    const r = ok('refund-issued');
    expect(r.subject).toBe('Refund issued: $10.00 for Show <One> & "Friends"');
    expect(r.html).toContain('Refunded so far: $10.00 of $30.00');
    expect(r.html).toContain('Order reference: cs_&lt;x&gt;');
    expect(ok('refund-issued', { ...PAYLOADS['refund-issued'], partial: false }).html).not.toContain('Refunded so far');
  });

  it('post-event: follow link unless following, next events, unsubscribe footer', () => {
    const r = ok('post-event');
    expect(r.html).toContain(`href="${APP}/organizer/${ORG}"`);
    expect(r.html).toContain(`href="${APP}/event/${EV2}">Next &lt;Show&gt;</a>`);
    expect(r.html).toContain(`href="${APP}/unsubscribe?t=${TOKEN}"`);
    expect(ok('post-event', { ...PAYLOADS['post-event'], following: true }).html).not.toContain('/organizer/');
  });

  it('marketing mails refuse to render without a valid unsubscribe token', () => {
    const r = renderTemplate('org-first-event', { org, marketing: true }, APP);
    expect(r).toEqual({ ok: false, error: 'org-first-event: unsubscribe_token missing' });
    const bad = renderTemplate('post-event', { ...PAYLOADS['post-event'], unsubscribe_token: '"><x' }, APP);
    expect(bad.ok).toBe(false);
  });

  it('transactional mails have no unsubscribe link; organizer mails say why they came', () => {
    expect(ok('refund-issued').html).not.toContain('unsubscribe');
    const r = ok('payout-sent');
    expect(r.html).not.toContain('unsubscribe');
    expect(r.html).toContain('because you help run Org &lt;7f&gt; &amp; Co on Exos');
    expect(r.subject).toBe('Payout sent: $1,234.56');
    expect(r.html).toContain('Reference: po_&lt;1&gt;');
    expect(ok('payout-pending').subject).toBe('Payout on the way: €500.00');
  });

  it('organizer digests: totals and links, no buyer data in, none out', () => {
    const d = ok('org-sales-digest');
    expect(d.subject).toBe('Org <7f> & Co: 2 tickets sold Sunday, September 27');
    expect(d.html).toContain('<strong>Total:</strong> 2 tickets, $160.00');
    const w = ok('org-weekly-summary');
    expect(w.html).toContain('Monday, September 21 to Sunday, September 27');
    expect(w.html).toContain('12 check-ins at the door');
    expect(w.html).toContain(`href="${APP}/dashboard/event/${EV2}">Next &lt;Show&gt;</a>, Monday, October 5 at 12:00 AM UTC: 40 of 100 sold`);
    const empty = ok('org-weekly-summary', { ...PAYLOADS['org-weekly-summary'], events: [], totals: [], checkins: 0, upcoming: [] });
    expect(empty.html).toContain('No sales this week.');
  });

  it('org-channel-report: tickets by channel, fees only where reported, comps apart', () => {
    const r = ok('org-channel-report');
    expect(r.subject).toBe('Org <7f> & Co: 3 tickets by channel, Oct 19 – Oct 25');
    expect(r.html).toContain('<strong>This week:</strong> 3 tickets, $50.00 gross, $47.50 net');
    expect(r.html).toContain(`href="${APP}/dashboard/event/${EV}"><strong>Show &lt;One&gt;</strong>`);
    expect(r.html).toContain(`href="${APP}/orgs/${ORG}/channels"`);
    // Instagram: week 2, to date 3, gross / fee / net to date.
    expect(r.html).toMatch(/Instagram<\/td><td[^>]*>2<\/td><td[^>]*>3<\/td><td[^>]*>\$75\.00<\/td><td[^>]*>\$1\.50<\/td><td[^>]*>\$71\.25<\/td>/);
    // Eventbrite: no prices or fees reported, never estimated.
    expect(r.html).toMatch(/Eventbrite<\/td><td[^>]*>1<\/td><td[^>]*>4<\/td><td[^>]*>not reported<\/td><td[^>]*>not reported<\/td><td[^>]*>not reported<\/td>/);
    // Luma: no dates, so no week figure.
    expect(r.html).toMatch(/Luma<\/td><td[^>]*>–<\/td><td[^>]*>5<\/td>/);
    expect(r.html).toContain('Luma: counts only, without sale dates');
    // Free channel: no fees.
    // Promoter codes are grouped: one row, no code in the mail.
    expect(r.html).toMatch(/Promoters<\/td><td[^>]*>0<\/td><td[^>]*>2<\/td><td[^>]*>\$0\.00<\/td><td[^>]*>none<\/td>/);
    expect(r.html).not.toContain('dj-kay');
    // Buyer-written sources: one "Other" row, last; none of the keys reach the mail.
    expect(r.html).toMatch(/Other<\/td><td[^>]*>3<\/td><td[^>]*>4<\/td>[^]*<\/table>/);
    expect(r.html.match(/>Other<\/td>/g)).toHaveLength(1);
    for (const bad of ['evil', '0100', '212', 'b-x-b', '&lt;b&gt;']) expect(r.html).not.toContain(bad);
    expect(r.html).toContain('Exos fee to date: $2.25');
    expect(r.html).toContain('Not sales: 6 comps, 3 imported attendees from other lists.');
    expect(r.html).not.toMatch(/Comps<\/td>/);
    expect(r.html).toContain('9 tickets came through channels that don&#39;t report prices or fees to Exos');
    expect(r.html).toContain('And 2 more events on your dashboard.');
    expect(r.html).toContain(`href="${APP}/unsubscribe?t=${TOKEN}"`);
    const none = ok('org-channel-report', { ...PAYLOADS['org-channel-report'], events: [], more_events: 0, totals: { week: [], to_date: [] } });
    expect(none.subject).toBe('Org <7f> & Co: 0 tickets by channel, Oct 19 – Oct 25');
    expect(none.html).toContain('<strong>This week:</strong> no tickets');
    expect(renderTemplate('org-channel-report', { ...PAYLOADS['org-channel-report'], events: [{ ...(PAYLOADS['org-channel-report'].events as object[])[0], id: 'javascript:x' }] }, APP).ok).toBe(false);
  });

  it('fee-free-ending: 14 days out and the last day', () => {
    expect(ok('fee-free-ending').subject).toBe('Your Exos free months end in 14 days');
    const last = ok('fee-free-ending', { ...PAYLOADS['fee-free-ending'], stage: '1d', days_left: 1 });
    expect(last.subject).toBe('Your Exos free months end October 12, 2026');
    expect(last.html).toContain('Exos keeps 3% of each sale');
  });

  it('inventory and publish alerts link to the organizer tools', () => {
    expect(ok('inventory-low').html).toContain('has 1 of 10 left');
    expect(ok('inventory-low').html).toContain(`href="${APP}/edit-event/${EV}"`);
    expect(ok('inventory-sold-out').subject).toBe('Sold out: GA for Show <One> & "Friends"');
    expect(ok('event-published').html).toContain(`href="${APP}/dashboard/event/${EV}/promote"`);
  });

  it('fixed-block-released: what to put back on the other platform, per type', () => {
    const r = ok('fixed-block-released');
    expect(r.subject).toBe('Put 96 tickets back on DICE <x>: Show <One> & "Friends"');
    expect(r.html).toContain('Put these back on sale on <strong>DICE &lt;x&gt;</strong>');
    expect(r.html).toContain('GA &lt;early&gt;</td><td style="padding:2px 12px 2px 0;text-align:right"><strong>95 tickets</strong>');
    expect(r.html).toContain('<strong>1 table of 6</strong>');
    expect(r.html).toContain('sold 23 of 120 on Exos');
    expect(r.html).toContain('2 more are still in a checkout or on a marketplace');
    expect(r.html).toContain(`href="${APP}/dashboard/event/${EV}"`);
    const none = ok('fixed-block-released', { ...PAYLOADS['fixed-block-released'], total_returned: 1, total_pending: 0 });
    expect(none.subject).toBe('Put 1 ticket back on DICE <x>: Show <One> & "Friends"');
    expect(none.html).not.toContain('still in a checkout');
  });

  it('dispute mails: amount, reason, deadline, links; no buyer data; recovery wording', () => {
    const o = ok('dispute-opened');
    expect(o.subject).toBe('Chargeback: $50.00 for Show <One> & "Friends"');
    expect(o.html).toContain('disputed a <strong>$50.00</strong> payment');
    expect(o.html).toContain('the cardholder says they didn&#39;t make the purchase');
    expect(o.html).toContain('Evidence is due Thursday, October 15 at 11:59 PM UTC');
    expect(o.html).toContain('$15.00 dispute fee');
    expect(o.html).toContain(`href="${APP}/dashboard/event/${EV}"`);
    expect(o.html).toContain('href="https://dashboard.stripe.com/test/disputes/du_1Abc"');
    expect(o.html).toContain('because you help run Org &lt;7f&gt; &amp; Co on Exos');
    expect(o.html).not.toContain('unsubscribe');
    const inquiry = ok('dispute-opened', { ...PAYLOADS['dispute-opened'], status: 'warning_needs_response', evidence_due_by: null, reason: 'odd_new_reason' });
    expect(inquiry.subject).toBe('Payment inquiry: $50.00 for Show <One> & "Friends"');
    expect(inquiry.html).toContain('Reason: odd new reason.');
    expect(inquiry.html).not.toContain('Evidence is due');
    const noEvent = ok('dispute-opened', { ...PAYLOADS['dispute-opened'], event: null });
    expect(noEvent.subject).toBe('Chargeback: $50.00');
    expect(noEvent.html).toContain(`href="${APP}/dashboard"`);

    const w = ok('dispute-won');
    expect(w.subject).toBe('Chargeback won: $50.00 for Show <One> & "Friends"');
    expect(w.html).toContain('href="https://dashboard.stripe.com/disputes/du_1Abc"');
    expect(w.html).toContain("Stripe's $15.00 dispute fee isn't returned");

    const l = ok('dispute-lost');
    expect(l.subject).toBe('Chargeback lost: $50.00 for Show <One> & "Friends"');
    expect(l.html).toContain('tickets are now void');
    expect(l.html).toContain('Nothing is taken from your payouts');
    const rec = ok('dispute-lost', { ...PAYLOADS['dispute-lost'], recovery_status: 'recovery_pending' });
    expect(rec.html).toContain('$65.00 (the amount plus the dispute fee) can be taken from a later payout');

    // A dispute id that isn't one never becomes a link.
    expect(renderTemplate('dispute-opened', { ...PAYLOADS['dispute-opened'], dispute_id: 'x"><script>' }, APP)).toEqual({
      ok: false, error: 'dispute-opened: dispute_id is not a dispute id',
    });
    expect(renderTemplate('dispute-lost', { ...PAYLOADS['dispute-lost'], amount_cents: undefined }, APP)).toEqual({
      ok: false, error: 'dispute-lost: amount_cents missing',
    });
  });

  it('signup-confirm: the confirm link carries the token, nothing else of the fan', () => {
    const r = ok('signup-confirm');
    expect(r.subject).toBe('Confirm: Org <7f> & Co emails and texts');
    expect(r.html).toContain(`${APP}/signup/confirm?t=${TOKEN}`);
    expect(r.html).toContain('Join &lt;the&gt; list');
    expect(r.html).toContain('signed in to Exos');
    expect(r.html).not.toContain('Unsubscribe');
    expect(ok('signup-confirm', { ...PAYLOADS['signup-confirm'], sms_requested: false }).subject).toBe('Confirm: Org <7f> & Co emails');
    expect(renderTemplate('signup-confirm', { ...PAYLOADS['signup-confirm'], token: '"><x>' }, APP)).toEqual({
      ok: false, error: 'signup-confirm: token missing',
    });
  });

  it('refuses rows it cannot render safely', () => {
    expect(renderTemplate('org-welcome', PAYLOADS['org-welcome'], null)).toEqual({
      ok: false, error: 'EXOS_APP_URL unset or invalid; mail links into the app',
    });
    expect(renderTemplate('nope', {}, APP)).toEqual({ ok: false, error: 'no renderer for template nope' });
    expect(renderTemplate('constructor', {}, APP).ok).toBe(false);
    expect(renderTemplate('org-welcome', 'x', APP)).toEqual({ ok: false, error: 'org-welcome: payload is not an object' });
    expect(renderTemplate('org-welcome', { org: { id: 'javascript:alert(1)', name: 'x' } }, APP)).toEqual({
      ok: false, error: 'org-welcome: id is not an id',
    });
    expect(renderTemplate('refund-issued', { event: event() }, APP)).toEqual({ ok: false, error: 'refund-issued: amount_cents missing' });
  });

  it('feeds the drain: renderMail leaves the rendered html alone and adds List-Unsubscribe', () => {
    const r = ok('post-event');
    const m = renderMail(r.html, `{{app_url}}/unsubscribe?t=${TOKEN}`, APP);
    expect(m).toEqual({ ok: true, html: r.html, headers: { 'List-Unsubscribe': `<${APP}/unsubscribe?t=${TOKEN}>` } });
  });
});

describe('offers, settlements and ticket counts', () => {
  it('offer-sent: the terms in words and a token link to the offer', () => {
    const r = ok('offer-sent');
    expect(r.subject).toBe('Offer from Org <7f> & Co: Band <x>, Thursday, November 19');
    expect(r.html).toContain('$1,000.00 versus 85% of net after expenses');
    expect(r.html).toContain(`${APP}/offer/${EV2}?t=${TOKEN}`);
    expect(r.html).toContain('through Exos');
    expect(renderTemplate('offer-sent', { ...PAYLOADS['offer-sent'], token: 'short' }, APP).ok).toBe(false);
  });

  it('settlement-finalized: a token link to the settlement', () => {
    expect(ok('settlement-finalized').html).toContain(`/settlement/${EV}?t=${TOKEN}`);
  });

  it('ticket-counts: numbers, capacity, sold elsewhere and the opt-out link', () => {
    const r = ok('ticket-counts');
    expect(r.subject).toMatch(/\(300 sold\)$/);
    expect(r.html).toContain('64% of 500 capacity');
    expect(r.html).toContain('20 sold elsewhere');
    expect(r.html).toContain(`/ticket-counts/opt-out?t=${TOKEN}`);
  });
});
