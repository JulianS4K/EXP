import { describe, it, expect } from 'vitest';
import { normalizeTopic, parseWebhookPayload, verifyWebhookAuthorization, WebhookPayloadError } from './webhook';

describe('verifyWebhookAuthorization', () => {
  it('accepts only the exact registered value', () => {
    expect(verifyWebhookAuthorization('Bearer s3cret', 'Bearer s3cret')).toBe(true);
    expect(verifyWebhookAuthorization('Bearer s3creT', 'Bearer s3cret')).toBe(false);
    expect(verifyWebhookAuthorization('Bearer s3cret ', 'Bearer s3cret')).toBe(false);
    expect(verifyWebhookAuthorization('Bearer s3cre', 'Bearer s3cret')).toBe(false);
  });

  it('fails closed on a missing header or unset expected value', () => {
    expect(verifyWebhookAuthorization(null, 'x')).toBe(false);
    expect(verifyWebhookAuthorization(undefined, 'x')).toBe(false);
    expect(verifyWebhookAuthorization('', '')).toBe(false);
    expect(verifyWebhookAuthorization('anything', '')).toBe(false);
  });
});

describe('normalizeTopic', () => {
  it('matches documented topic names loosely', () => {
    expect(normalizeTopic('Sales')).toBe('Sales');
    expect(normalizeTopic('SalesTopic')).toBe('Sales');
    expect(normalizeTopic('provisional_sale')).toBe('ProvisionalSale');
    expect(normalizeTopic('CANCEL-PROVISIONAL-SALE')).toBe('CancelProvisionalSale');
    expect(normalizeTopic('SellerListingUpdatesTopic')).toBe('SellerListingUpdates');
    expect(normalizeTopic('ReTransferTicket')).toBe('ReTransferTicket');
  });

  it('returns unknown for anything else', () => {
    expect(normalizeTopic('Refunds')).toBe('unknown');
    expect(normalizeTopic(null)).toBe('unknown');
    expect(normalizeTopic('')).toBe('unknown');
  });
});

describe('parseWebhookPayload', () => {
  it('parses a sale payload and classifies it', () => {
    const p = parseWebhookPayload({
      topic: 'Sales',
      action: 'Created',
      barcodes: [],
      _embedded: { sale: { id: 42, created_at: '2026-09-26T00:00:00Z', number_of_tickets: 2, status: 'Pending' } },
    });
    expect(p.kind).toBe('Sales');
    expect(p.action).toBe('Created');
    expect(p._embedded?.sale?.id).toBe(42);
  });

  it('tolerates null/missing optional fields', () => {
    const p = parseWebhookPayload({ topic: 'Ping' });
    expect(p).toMatchObject({ kind: 'Ping', action: null, barcodes: null });
  });

  it('rejects bodies that are not StubHub payloads', () => {
    expect(() => parseWebhookPayload(null)).toThrow(WebhookPayloadError);
    expect(() => parseWebhookPayload([])).toThrow(WebhookPayloadError);
    expect(() => parseWebhookPayload({ topic: 5 })).toThrow(/topic/);
    expect(() => parseWebhookPayload({ barcodes: 'x' })).toThrow(/barcodes/);
    expect(() => parseWebhookPayload({ _embedded: [] })).toThrow(/_embedded/);
  });
});
