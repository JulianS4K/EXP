import { describe, expect, it } from 'vitest';
import {
  BodyFieldError, importedAttendeeFields, membershipIssueFields, membershipProductFields, membershipUpdateFields,
} from '../../supabase/functions/_shared/api/memberships.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';

describe('membership API bodies (mig 20261102100000)', () => {
  it('product: wrapped or flat; Opendate amounts become price + billing; venues dropped', () => {
    expect(membershipProductFields({ membership_product: { name: 'VIP', default_annual_amount_cents: 5000, venue_ownership_ids: [1], team_id: 3 } }, 'create'))
      .toEqual({ name: 'VIP', price_cents: 5000, billing: 'year' });
    expect(membershipProductFields({ name: 'M', default_monthly_amount_cents: '500' }, 'create'))
      .toEqual({ name: 'M', price_cents: 500, billing: 'month' });
    expect(membershipProductFields({ default_monthly_amount_cents: 700 }, 'update')).toEqual({ price_cents: 700 });
    expect(membershipProductFields({ price_cents: 900, billing: 'once', default_monthly_amount_cents: 0 }, 'create'))
      .toEqual({ price_cents: 900, billing: 'once' });
    expect(() => membershipProductFields({ default_monthly_amount_cents: 5, default_annual_amount_cents: 50 }, 'create')).toThrow(BodyFieldError);
    expect(() => membershipProductFields({ status: 'archived' }, 'update')).toThrow(/publish/);
    // Unknown fields pass through, for the SQL to refuse (never silently ignored).
    expect(membershipProductFields({ colour: 'red' }, 'update')).toEqual({ colour: 'red' });
  });
  it('issue: Opendate names map; body idempotency_key handed back', () => {
    expect(membershipIssueFields({ membership: {
      product_id: 'p', email: 'a@b.co', first_name: 'Dana', last_name: 'Lee', rebilling_date: '2027-01-01', notes: 'n',
      idempotency_key: 'idem-12345', skip_welcome_email: true, phone_number: '5', import_metadata: {},
    } })).toEqual({
      fields: { product_id: 'p', email: 'a@b.co', member_name: 'Dana Lee', expires_at: '2027-01-01', staff_notes: 'n' },
      idempotencyKey: 'idem-12345',
    });
    expect(() => membershipIssueFields({ membership_product_price_id: 7, email: 'a@b.co' })).toThrow(/product_id/);
  });
  it('update and imported attendee: names joined, Opendate keys moved', () => {
    expect(membershipUpdateFields({ membership: { first_name: 'Dana', last_name: '' } })).toEqual({ member_name: 'Dana' });
    expect(membershipUpdateFields({ current_period_end: '2028-01-01', member_name: 'X', first_name: 'Y' }))
      .toEqual({ expires_at: '2028-01-01', member_name: 'X' });
    expect(importedAttendeeFields({ migrated_attendee: { first_name: 'Ann', last_name: 'Lee', barcode: 'P 1' } }))
      .toEqual({ guest_name: 'Ann Lee', code: 'P 1' });
  });
  it('routes', () => {
    expect(matchRoute('POST', '/membership-products')?.route.id).toBe('create-membership-product');
    expect(matchRoute('POST', '/membership-products/x/archive')?.route.id).toBe('archive-membership-product');
    expect(matchRoute('PATCH', '/memberships/m1')?.route).toMatchObject({ id: 'update-membership', scope: 'commerce:write' });
    expect(matchRoute('POST', '/memberships')?.route.id).toBe('issue-membership');
    expect(matchRoute('DELETE', '/migrated_attendees/g1')?.route).toMatchObject({ id: 'delete-migrated-attendee', scope: 'tickets:write' });
    expect(matchRoute('GET', '/migrated-attendees')?.route.paged).toBe(true);
  });
});
