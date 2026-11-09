import { describe, expect, it } from 'vitest';
import { canWriteRentalTemplates, depositDueDate, lineTotal, rentalActions, rentalTotals } from './rentalInvoice';
import { emptyInboundForm, inboundActions, inboundErrorMessage, inboundFormPath, inboundPayload, MAX_SUBMISSION_BYTES } from './inbound';

describe('rentalInvoice', () => {
  // The same numbers the SQL harness checks (test_templates_inbound.sql TI4).
  const items = [
    { title: 'Room hire', cost_cents: 50000 },
    { title: 'Bar staff', quantity: '2.5', cost_cents: 3000 },
    { title: 'Security', cost_type: 'per_head' as const, cost_cents: 150 },
  ];
  it('matches the database totals', () => {
    const t = rentalTotals(items, 80, 5000, [{ name: 'Sales tax', rate_percent: '8.875' }],
      [{ deposit_type: 'percent', value: 50 }, { deposit_type: 'flat', value: 10000 }]);
    expect([t.subtotal_cents, t.discount_cents, t.taxable_cents, t.tax_cents, t.total_cents, t.deposits_cents])
      .toEqual([69500, 5000, 64500, 5724, 70224, 45112]);
    expect(t.lines).toEqual([50000, 7500, 12000]);
  });
  it('caps the discount, treats a missing head count as zero', () => {
    expect(rentalTotals([{ title: 'x', cost_cents: 100 }], null, 900).total_cents).toBe(0);
    expect(lineTotal({ title: 'x', cost_type: 'per_head', cost_cents: 100 }, null)).toBe(0);
    expect(lineTotal({ title: 'x', quantity: 'junk', cost_cents: 100 }, 1)).toBe(0);
  });
  it('rounds half away from zero like Postgres', () => {
    expect(rentalTotals([{ title: 'x', cost_cents: 50 }], 0, 0, [{ name: 't', rate_percent: 5 }]).tax_cents).toBe(3);
  });
  it('dates deposits before the rental', () => {
    expect(depositDueDate({ deposit_type: 'flat', value: 1, due_date_type: 'relative', relative_due_days: 14 }, '2026-12-12')).toBe('2026-11-28');
    expect(depositDueDate({ deposit_type: 'flat', value: 1, due_date_type: 'specific', specific_due_date: '2026-12-01' }, null)).toBe('2026-12-01');
    expect(depositDueDate({ deposit_type: 'flat', value: 1 }, null)).toBeNull();
  });
  it('allows actions by status and role', () => {
    expect(rentalActions('draft', 'finance')).toEqual({ edit: true, delete: true, issue: true, pay: false, unpay: false, void: false });
    expect(rentalActions('issued', 'manager')).toEqual({ edit: false, delete: false, issue: false, pay: true, unpay: false, void: true });
    expect(rentalActions('paid', 'owner')).toMatchObject({ pay: false, unpay: true, void: true });
    expect(Object.values(rentalActions('void', 'owner')).some(Boolean)).toBe(false);
    expect(Object.values(rentalActions('draft', 'content')).some(Boolean)).toBe(false);
    expect(rentalActions('draft', null, true).issue).toBe(true);
    expect([canWriteRentalTemplates('finance'), canWriteRentalTemplates('manager')]).toEqual([false, true]);
  });
});

describe('inbound', () => {
  const ok = { ...emptyInboundForm(), artist_name: ' The Ramblers ', email: ' Jo@Agency.example ' };
  it('builds the payload', () => {
    const r = inboundPayload({
      ...ok, genres: 'folk, , americana', preferred_dates: ['2027-03-06', '2027-03-05', '2027-03-05', 'bad'],
      links: { spotify: ' https://open.spotify.com/artist/1 ', instagram: '' }, expected_draw: '200', venue_id: 'v1',
    });
    expect(r).toEqual({ ok: true, payload: {
      artist_name: 'The Ramblers', email: 'jo@agency.example', contact_role: 'artist', dates_flexible: true,
      links: { spotify: 'https://open.spotify.com/artist/1' }, genres: ['folk', 'americana'], venue_id: 'v1',
      preferred_dates: ['2027-03-05', '2027-03-06'], expected_draw: 200,
    } });
  });
  it('refuses what the server would', () => {
    expect(inboundPayload({ ...ok, artist_name: ' ' }).ok).toBe(false);
    expect(inboundPayload({ ...ok, email: 'nope' }).ok).toBe(false);
    expect(inboundPayload({ ...ok, links: { website: 'http://x.example' } }).ok).toBe(false);
    expect(inboundPayload({ ...ok, expected_draw: '1.5' }).ok).toBe(false);
    expect(inboundPayload({ ...ok, genres: Array.from({ length: 11 }, (_, i) => `g${i}`).join(',') }).ok).toBe(false);
    expect(inboundPayload({ ...ok, message: 'x'.repeat(5001) }).ok).toBe(false);
    expect(MAX_SUBMISSION_BYTES).toBe(16384);
  });
  it('passes the honeypot through for the server to drop', () => {
    const r = inboundPayload({ ...ok, homepage: 'http://spam' });
    expect(r.ok && r.payload.homepage).toBe('http://spam');
  });
  it('words server errors for visitors', () => {
    expect(inboundErrorMessage({ code: '54000', message: 'too many requests from this network; try again later' }))
      .toBe('Too many requests from this network; try again later.');
    expect(inboundErrorMessage({ code: 'P0002' })).toMatch(/isn't taking/);
    expect(inboundErrorMessage({ code: 'XX000', message: 'internal detail' })).not.toMatch(/internal/);
  });
  it('gives actions by role', () => {
    expect(inboundActions('content')).toEqual({ review: true, hold: false, delete: false, settings: false });
    expect(inboundActions('manager')).toEqual({ review: true, hold: true, delete: true, settings: true });
    expect(inboundActions('manager', false, true).hold).toBe(false);
    expect(inboundActions('finance').review).toBe(false);
    expect(inboundActions('scanner', true).delete).toBe(true);
    expect(inboundFormPath('my org')).toBe('/book/my%20org');
  });
});
