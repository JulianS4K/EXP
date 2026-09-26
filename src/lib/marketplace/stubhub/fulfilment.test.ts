import { describe, it, expect } from 'vitest';
import {
  FulfilmentError,
  attachETicketsRequest,
  buyerEmail,
  confirmSaleRequest,
  eticketUrlsRequest,
  exosClaimUrl,
  mobileTransferRequest,
  saleDeadline,
  type MobileTransferProvider,
} from '.';

describe('sale request builders', () => {
  it('confirm', () => {
    expect(confirmSaleRequest()).toEqual({ confirmed: true });
  });

  it('mobile transfer validates the provider and trims the confirmation number', () => {
    expect(mobileTransferRequest('Ticketmaster', ' TM-123 ')).toEqual({
      confirmed: true,
      mobile_provider: 'Ticketmaster',
      transfer_confirmation_number: 'TM-123',
    });
    expect(() => mobileTransferRequest('Exos' as MobileTransferProvider, 'x')).toThrow(FulfilmentError);
    expect(() => mobileTransferRequest('AXS', '  ')).toThrow(/confirmation/);
  });

  it('attach e-tickets needs unique ids', () => {
    expect(attachETicketsRequest([1, 2])).toEqual({ confirmed: true, eticket_ids: [1, 2] });
    expect(() => attachETicketsRequest([])).toThrow(FulfilmentError);
    expect(() => attachETicketsRequest([1, 1])).toThrow(/duplicate/);
  });
});

describe('saleDeadline', () => {
  const now = new Date('2026-10-01T12:00:00Z');
  const sale = { confirm_by: '2026-10-01T18:00:00Z', ship_by: '2026-10-01T10:00:00Z' };

  it('asks for confirmation first', () => {
    expect(saleDeadline(sale, { confirmed: false, delivered: false }, now)).toEqual({
      action: 'confirm',
      due: new Date('2026-10-01T18:00:00Z'),
      overdue: false,
      remainingMs: 6 * 3600_000,
    });
  });

  it('then delivery, flagging overdue', () => {
    expect(saleDeadline(sale, { confirmed: true, delivered: false }, now)).toMatchObject({
      action: 'deliver',
      overdue: true,
      remainingMs: -2 * 3600_000,
    });
  });

  it('nothing once delivered; tolerates missing or bad dates', () => {
    expect(saleDeadline(sale, { confirmed: true, delivered: true }, now).action).toBe('none');
    expect(saleDeadline({ confirm_by: null, ship_by: 'garbage' }, { confirmed: false, delivered: false }, now)).toEqual({
      action: 'confirm',
      due: null,
      overdue: false,
      remainingMs: null,
    });
  });
});

describe('e-ticket URL route', () => {
  const T1 = '0b6f1c2e-1111-4a2b-9c3d-000000000001';
  const T2 = '0b6f1c2e-1111-4a2b-9c3d-000000000002';

  it('builds https claim links from the app origin', () => {
    expect(exosClaimUrl('https://exos.example.test/bridge/', T1.toUpperCase())).toBe(
      `https://exos.example.test/bridge/claim/${T1}`,
    );
    expect(exosClaimUrl('https://exos.example.test', T1)).toBe(`https://exos.example.test/claim/${T1}`);
    // Query and fragment on the base are dropped.
    expect(exosClaimUrl('https://exos.example.test/bridge?x=1#y', T1)).toBe(`https://exos.example.test/bridge/claim/${T1}`);
    expect(() => exosClaimUrl('http://exos.example.test', T1)).toThrow(/https/);
    expect(() => exosClaimUrl('not a url', T1)).toThrow(/is not a URL/);
    expect(() => exosClaimUrl('https://exos.example.test', '../admin')).toThrow(/uuid/);
  });

  it('confirms the sale with one url per ticket', () => {
    const urls = [T1, T2].map((t) => exosClaimUrl('https://exos.example.test', t));
    expect(eticketUrlsRequest(urls, 2)).toEqual({
      confirmed: true,
      eticket_urls: urls.map((url) => ({ url })),
    });
  });

  it('refuses a count mismatch, duplicates, or non-https urls', () => {
    const u = exosClaimUrl('https://exos.example.test', T1);
    expect(() => eticketUrlsRequest([], 0)).toThrow(FulfilmentError);
    expect(() => eticketUrlsRequest([u], 2)).toThrow(/2 ticket\(s\) but 1 url/);
    expect(() => eticketUrlsRequest([u, u], 2)).toThrow(/duplicate/);
    expect(() => eticketUrlsRequest(['http://x.test/claim/1'], 1)).toThrow(/https/);
    expect(() => eticketUrlsRequest(['nope'], 1)).toThrow(/is not a URL/);
  });

  it('finds the buyer email in any ticketholders shape', () => {
    expect(buyerEmail({ id: 1, email_address: ' Buyer@Example.TEST ' })).toBe('buyer@example.test');
    expect(buyerEmail([{ email_address: null }, { email_address: 'b@x.test' }])).toBe('b@x.test');
    expect(buyerEmail({ _embedded: { items: [{ email_address: 'c@x.test' }] } })).toBe('c@x.test');
  });

  it('returns null when there is no usable email', () => {
    expect(buyerEmail(null)).toBeNull();
    expect(buyerEmail({ full_name: 'No Email' })).toBeNull();
    expect(buyerEmail([{ email_address: 'not-an-email' }])).toBeNull();
  });
});
