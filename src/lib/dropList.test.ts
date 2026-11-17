// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import {
  browserToken, cleanCode, dropCsvRows, dropSource, linkToken, onSaleAt, parseStatus, parseSummary, saleState, sourceLabel,
} from './dropList';

const ts = (ms: number) => ({ toMillis: () => ms });
const NOW = Date.UTC(2026, 10, 18, 12);
const later = ts(NOW + 3_600_000);
const earlier = ts(NOW - 3_600_000);

describe('saleState: which call to action the event page shows', () => {
  it('not yet on sale -> the drop list (every public sellable type opens later)', () => {
    expect(saleState([{ capacity: 100, sold: 0, salesStart: later }, { capacity: 50, sold: 0, salesStart: ts(NOW + 7_200_000) }], NOW)).toBe('not_yet');
  });
  it('hidden types and closed (capacity 0) types do not count, like _exos_drop_open_at', () => {
    expect(saleState([
      { capacity: 100, sold: 0, salesStart: later },
      { capacity: 20, sold: 0, salesStart: null, visibility: 'hidden' },
      { capacity: 0, sold: 0, salesStart: null },
    ], NOW)).toBe('not_yet');
  });
  it('one public type on sale (no start, or a start in the past) -> on sale, no drop list', () => {
    expect(saleState([{ capacity: 100, sold: 0, salesStart: later }, { capacity: 100, sold: 10, salesStart: null }], NOW)).toBe('on_sale');
    expect(saleState([{ capacity: 100, sold: 0, salesStart: earlier }], NOW)).toBe('on_sale');
  });
  it('on sale and every open type sold -> sold out, which keeps the existing waitlist', () => {
    expect(saleState([{ capacity: 10, sold: 10, salesStart: earlier }, { capacity: 5, sold: 0, salesStart: later }], NOW)).toBe('sold_out');
  });
  it('nothing public to sell -> closed', () => {
    expect(saleState([], NOW)).toBe('closed');
    expect(saleState(undefined, NOW)).toBe('closed');
    expect(saleState([{ capacity: 10, sold: 0, salesStart: later, visibility: 'hidden' }], NOW)).toBe('closed');
  });
  it('onSaleAt is the earliest public start', () => {
    expect(onSaleAt([{ capacity: 1, salesStart: ts(NOW + 5) }, { capacity: 1, salesStart: ts(NOW + 2) }, { capacity: 0, salesStart: ts(NOW + 1) }])?.getTime())
      .toBe(NOW + 2);
    expect(onSaleAt([])).toBeNull();
  });
});

describe('drop list helpers', () => {
  it('sends only the promoter code and UTM tags as the source', () => {
    expect(dropSource({ promoter: 'dj_k', utm_source: 'instagram', fbclid: 'x', ref: 'abcdefghij', ai_ref: 'claude' } as never))
      .toEqual({ promoter: 'dj_k', utm_source: 'instagram' });
    expect(dropSource({})).toBeNull();
    expect(dropSource(null)).toBeNull();
  });
  it('reads 64-hex link tokens and 6-digit codes only', () => {
    const t = 'a'.repeat(64);
    expect(linkToken(`?t=${t}`)).toBe(t);
    expect(linkToken('?t=abc')).toBeNull();
    expect(linkToken('')).toBeNull();
    expect(cleanCode(' 123 456 ')).toBe('123456');
    expect(cleanCode('12345')).toBeNull();
    expect(cleanCode('abcdef')).toBeNull();
  });
  it('keeps one 256-bit browser token per event for the visit', () => {
    const a = browserToken('ev-1', () => new Uint8Array(32).fill(171));
    expect(a).toBe('ab'.repeat(32));
    expect(browserToken('ev-1', () => new Uint8Array(32).fill(1))).toBe(a);
    expect(browserToken('ev-2', () => new Uint8Array(32).fill(1))).toBe('01'.repeat(32));
  });
  it('parses the status and the organizer summary', () => {
    const s = parseStatus({ open: true, on_sale_at: '2026-11-18T15:00:00Z', list_presale: true, joined: true, sms: true, phone_hint: '…0101',
      email_consent_text: 'Email me once', sms_consent_text: 'Text me once. Reply STOP' });
    expect(s).toMatchObject({ open: true, listPresale: true, joined: true, sms: true, phoneHint: '…0101', emailConsentText: 'Email me once' });
    expect(parseStatus(null)).toMatchObject({ open: false, joined: false, onSaleAt: null, smsConsentText: null });
    const m = parseSummary({ open: true, signups: 12, confirmed: 9, pending: 3, sms: 4, left: 1, notified: 0, texts_queued: 0,
      sources: [{ label: 'promoter:dj_k', promoter: 'dj_k', signups: 5, confirmed: 4 }, { label: 'instagram', utm_source: 'instagram', utm_medium: 'story', signups: 4, confirmed: 3 }],
      presale: { status: 'set', minutes: 60, tier_id: 't1', tier_name: 'List presale', code: 'LISTABC', opens_at: '2026-11-18T14:00:00Z' },
      can_manage: true });
    expect(m).toMatchObject({ signups: 12, confirmed: 9, sms: 4, canManage: true });
    expect(m.presale).toMatchObject({ status: 'set', minutes: 60, tierName: 'List presale', code: 'LISTABC' });
    expect(m.sources.map(sourceLabel)).toEqual(['Promoter dj_k', 'instagram / story']);
    expect(sourceLabel({ promoter: null, utmSource: null, utmMedium: null, utmCampaign: null })).toBe('Direct (no tag)');
    expect(parseSummary({}).presale.status).toBe('off');
  });
  it('CSV rows: email, dates, texts yes / no, source; never a phone', () => {
    const rows = dropCsvRows([{ email: 'a@x.com', joined_at: 'j', confirmed_at: 'c', texts: true, promoter: 'p', utm_source: 'ig', phone: '+12125550101' }]);
    expect(rows).toEqual([['a@x.com', 'j', 'c', 'yes', 'p', 'ig', '', '']]);
    expect(JSON.stringify(rows)).not.toContain('+1212');
  });
});
