// Per-partner caps (mig 20261104200000): the PUT body exos-api sends the SQL,
// the dashboard field, and the 409 a reservation over a cap answers.
import { describe, expect, it } from 'vitest';
import {
  capSummary, findCap, normalizePartnerCaps, parseCapField, type PartnerCap,
} from '../../supabase/functions/_shared/partners/caps.ts';
import { RequestError, rpcAnswer, userTokenMayCall } from '../../supabase/functions/_shared/api/request.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';

const P = 'b7e6d5c4-3b2a-4190-8f7e-6d5c4b3a2918';
const T = '8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f';

describe('normalizePartnerCaps', () => {
  it('takes ticket_type_id or tier_id, null tier for the event, null max to remove', () => {
    expect(normalizePartnerCaps([
      { partner_id: P, ticket_type_id: T, max_tickets: 10 },
      { partner_id: P.toUpperCase(), tier_id: T, max_tickets: null },
      { partner_id: P, max_tickets: 0 },
    ])).toEqual([
      { partner_id: P, tier_id: T, max_tickets: 10 },
      { partner_id: P, tier_id: T, max_tickets: null },
      { partner_id: P, tier_id: null, max_tickets: 0 },
    ]);
  });
  it('refuses bad items with 400 before the database', () => {
    for (const bad of [
      [], [null], ['x'], [{ partner_id: 'nope', max_tickets: 1 }], [{ partner_id: P }],
      [{ partner_id: P, max_tickets: -1 }], [{ partner_id: P, max_tickets: 2.5 }], [{ partner_id: P, max_tickets: '5' }],
      [{ partner_id: P, max_tickets: 100001 }], [{ partner_id: P, ticket_type_id: 'GA', max_tickets: 1 }],
      Array.from({ length: 201 }, () => ({ partner_id: P, max_tickets: 1 })),
    ]) {
      expect(() => normalizePartnerCaps(bad as unknown[])).toThrow(RequestError);
    }
  });
});

describe('dashboard helpers', () => {
  it('parseCapField: blank removes, whole numbers up to 100000', () => {
    expect(parseCapField('')).toBeNull();
    expect(parseCapField(' 12 ')).toBe(12);
    expect(parseCapField('0')).toBe(0);
    expect(parseCapField('100001')).toBeUndefined();
    expect(parseCapField('1.5')).toBeUndefined();
    expect(parseCapField('-3')).toBeUndefined();
  });
  it('capSummary and findCap', () => {
    const caps: PartnerCap[] = [
      { partner_id: P, partner_label: 'StubHub', tier_id: null, tier_name: null, max_tickets: 10, used: 4, left: 6 },
      { partner_id: P, partner_label: 'StubHub', tier_id: T, tier_name: 'GA', max_tickets: 4, used: 4, left: 0 },
    ];
    expect(capSummary(caps[0])).toBe('6 of 10 left');
    expect(capSummary(caps[1])).toBe('cap reached (4 of 4)');
    expect(capSummary({ max_tickets: 0, used: 0, left: 0 })).toBe('stopped (cap 0)');
    expect(findCap(caps, P, null)?.max_tickets).toBe(10);
    expect(findCap(caps, P, T)?.tier_name).toBe('GA');
    expect(findCap(caps, 'other', null)).toBeUndefined();
  });
});

describe('the API', () => {
  it('a reservation over the cap answers 409 partner_cap_reached with what is left', () => {
    const a = rpcAnswer({
      code: 'EXCAP', message: 'partner_cap_reached: this partner may hold or sell 2 more of GA',
      details: JSON.stringify({ left: 2, max_tickets: 12, tier_id: T }),
    });
    expect(a?.status).toBe(409);
    expect(a?.body).toMatchObject({ reason: 'partner_cap_reached', left: 2, ticket_type_id: T });
    // A detail that isn't ours keeps the reason, with nulls.
    expect(rpcAnswer({ code: 'EXCAP', message: 'x', details: 'garbage' })?.body).toMatchObject({ left: null, ticket_type_id: null });
  });
  it('routes: GET / PUT /events/:id/partner-caps; dashboard tokens may set them', () => {
    expect(matchRoute('GET', '/events/3f6b2c1e-8a4d-4e2f-9b1a-7c5d0e9f2a14/partner-caps')?.route.id).toBe('get-event-partner-caps');
    expect(matchRoute('PUT', '/events/3f6b2c1e-8a4d-4e2f-9b1a-7c5d0e9f2a14/partner-caps')?.route.id).toBe('set-event-partner-caps');
    expect(userTokenMayCall('pat', 'PUT', 'set-event-partner-caps')).toBe(true);
  });
});
