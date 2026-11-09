import { describe, expect, it } from 'vitest';
import { BodyError } from '../../supabase/functions/_shared/api/booking.ts';
import {
  eventFromTemplateBody, eventTemplateBody, inboundBody, inboundPatch, noteTemplateBody, rentalInvoiceBody, rentalTemplateBody,
} from '../../supabase/functions/_shared/api/templates.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';

const U = '9f30c5a1-1c2d-4e3f-8a9b-0c1d2e3f4a5b';

describe('template routes', () => {
  it('match Exos and Opendate spellings with the right scopes', () => {
    expect(matchRoute('GET', '/event_templates')?.route.id).toBe('list-event-templates');
    expect(matchRoute('POST', '/event-templates/x/events')?.route).toMatchObject({ id: 'create-event-from-template', scope: 'events:write' });
    expect(matchRoute('PATCH', '/rental_invoice_templates/x')?.route).toMatchObject({ id: 'update-rental-invoice-template', scope: 'booking:write' });
    expect(matchRoute('POST', '/rental-invoices/x/issue')?.route).toMatchObject({ id: 'issue-rental-invoice', scope: 'finance:write' });
    expect(matchRoute('GET', '/inbound_submissions/x')?.route).toMatchObject({ id: 'get-inbound-submission', scope: 'booking:read' });
    expect(matchRoute('DELETE', '/inbound-submissions/x')?.route.id).toBe('delete-inbound-submission');
    expect(matchRoute('DELETE', '/events/x')?.route).toMatchObject({ id: 'delete-event', scope: 'events:write' });
    expect(matchRoute('PUT', '/rental-invoices/x')).toBeNull();
  });
});

describe('template bodies', () => {
  it('event template: wrapped, aliases, from an event', () => {
    expect(eventTemplateBody({ event_template: { name: 'Club', ticket_types: [], capacity: '300' } }, false))
      .toEqual({ row: { name: 'Club', tiers: [], capacity: 300 }, fromEventId: null });
    expect(eventTemplateBody({ from_event_id: U, name: 'Copy' }, false)).toEqual({ row: { name: 'Copy' }, fromEventId: U });
    expect(() => eventTemplateBody({ from_event_id: U, capacity: 3 }, false)).toThrow(BodyError);
    expect(() => eventTemplateBody({}, false)).toThrow(/name is required/);
    expect(eventTemplateBody({ status: 'archived' }, true).row).toEqual({ status: 'archived' });
    expect(() => eventTemplateBody({ org_id: U }, true)).toThrow(/Unknown/);
    expect(() => eventTemplateBody({ event_fields: [] }, true)).toThrow(/object/);
    expect(() => eventTemplateBody({ doors_offset_minutes: 2000 }, true)).toThrow(/0 to 1440/);
  });
  it('create from template', () => {
    expect(eventFromTemplateBody({ starts_at: '2026-12-04T03:00:00Z', venue_id: U })).toEqual({ starts_at: '2026-12-04T03:00:00Z', exos_venue_id: U });
    expect(() => eventFromTemplateBody({ starts_at: 'soon' })).toThrow(/ISO/);
    expect(() => eventFromTemplateBody({ status: 'published' })).toThrow(/Unknown/);
  });
  it('note template', () => {
    expect(noteTemplateBody({ note_template: { title: 'A', body: 'B', team_id: 4 } }, false)).toEqual({ title: 'A', body: 'B' });
    expect(() => noteTemplateBody({ title: 'A' }, false)).toThrow(/body is required/);
  });
  it('rental template: Opendate names, ignored fields', () => {
    expect(rentalTemplateBody({ rental_invoice_template: {
      title: 'Room', terms_and_conditions: '<p>x</p>', rental_invoice_items_attributes: [{ title: 'Hire', cost_cents: 1 }],
      team_membership_id: 9, type: 'RentalInvoices::Template', currency: 'usd',
    } }, false)).toEqual({ title: 'Room', terms: '<p>x</p>', items: [{ title: 'Hire', cost_cents: 1 }], currency: 'USD' });
    expect(() => rentalTemplateBody({ title: 'x', status: 'paid' }, false)).toThrow(/status/);
    expect(() => rentalTemplateBody({ title: 'x', total_cents: 1 }, false)).toThrow(/Unknown/);
  });
  it('rental invoice: ids checked, numbers and totals refused', () => {
    expect(rentalInvoiceBody({ template_id: U, calendar_event_id: U }, false)).toEqual({ template_id: U, event_id: U });
    expect(() => rentalInvoiceBody({}, false)).toThrow(/title is required/);
    expect(() => rentalInvoiceBody({ hold_id: 'h1', title: 'x' }, false)).toThrow(/UUID/);
    expect(() => rentalInvoiceBody({ number: 'R-1' }, true)).toThrow(/Unknown/);
    expect(() => rentalInvoiceBody({ template_id: U }, true)).toThrow(/Unknown/);
  });
  it('inbound: Opendate form fields map on', () => {
    expect(inboundBody({ inbound_submission: {
      team_id: 1, venue_ownership_id: U, artist_name: 'The Blues Band', name: 'John', email: 'b@x.co',
      spotify: 'https://open.spotify.com/a', instagram: '', genres: 'blues, rock',
    } })).toEqual({ artist_name: 'The Blues Band', contact_name: 'John', email: 'b@x.co', venue_id: U, genres: ['blues', 'rock'],
      links: { spotify: 'https://open.spotify.com/a' } });
    expect(() => inboundBody({ email: 'x@y.co' })).toThrow(/artist_name/);
    expect(() => inboundBody({ artist_name: 'x', status: 'accepted' })).toThrow(/Unknown/);
    expect(() => inboundBody({ artist_name: 'x', venue_id: 'v' })).toThrow(/UUID/);
    expect(inboundPatch({ status: 'declined' })).toEqual({ status: 'declined', staff_note: null });
    expect(() => inboundPatch({})).toThrow(BodyError);
    expect(() => inboundPatch({ status: 'spam' })).toThrow(/status/);
  });
});
