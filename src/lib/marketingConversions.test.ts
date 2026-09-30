import { describe, expect, it } from 'vitest';
import {
  type ConversionRow, type Credential, normalizeEmail, normalizeEmailGoogle, normalizePhone,
  redactRequest, sha256Hex, eventSourceUrl, tooOld,
} from '../../supabase/functions/_shared/conversions/common.ts';
import { buildMeta, metaFbc, META_GRAPH_VERSION } from '../../supabase/functions/_shared/conversions/meta.ts';
import { buildTikTok } from '../../supabase/functions/_shared/conversions/tiktok.ts';
import { buildGa4 } from '../../supabase/functions/_shared/conversions/ga4.ts';
import { buildReddit } from '../../supabase/functions/_shared/conversions/reddit.ts';
import { buildSnap } from '../../supabase/functions/_shared/conversions/snap.ts';
import { buildGoogleAds } from '../../supabase/functions/_shared/conversions/googleAds.ts';
import { buildConversionRequest, plannedOnly, scrubSecret, sendConversion } from '../../supabase/functions/_shared/conversions/send.ts';

// The gmail hashes are the same constants as tests/exos/test_marketing_conversions.sql
// (M4), so the SQL trigger's hashes and these helpers agree.
const NOW = new Date('2026-09-30T12:00:00Z');
const CTX = { appBase: 'https://exos.example', now: NOW };

async function row(over: Partial<ConversionRow> = {}, payload: Partial<ConversionRow['payload']> = {}): Promise<ConversionRow> {
  return {
    id: 'r1',
    platform: 'meta',
    event_name: 'Purchase',
    event_id_dedupe: 'cs_test_abc123',
    occurred_at: '2026-09-30T11:00:00Z',
    value_cents: 5000,
    currency: 'usd',
    payload: {
      transaction_id: 'cs_test_abc123',
      em: await sha256Hex('ae-buyer@x.com'),
      em_google: await sha256Hex('ae-buyer@x.com'),
      user_agent: 'Mozilla/5.0 (iPhone)',
      ad_ids: {
        fbp: 'fb.1.1690000000000.123456789', fbclid: 'IwAR0abc', ttclid: 'E.C.P.tt', ga_client_id: '123456789.1690000000',
        gclid: 'Cj0KCQ', rdt_cid: 'rdt-1', ScCid: 'sc-1',
      },
      click_at: '2026-09-30T10:55:00Z',
      quantity: 2,
      event: { id: 'ev-1', slug: 'ae-show', name: 'AE Show' },
      ...payload,
    },
    ...over,
  };
}
const cred = (config: Record<string, string>, extra: Partial<Credential> = {}): Credential => ({
  config, secret: 'SECRET-token-123', test_event_code: null, ...extra,
});

describe('normalization and hashing (parity with the SQL helpers)', () => {
  it('lower-cases and trims emails; Google also drops gmail dots', async () => {
    expect(normalizeEmail('  AE-Buyer@X.com ')).toBe('ae-buyer@x.com');
    expect(normalizeEmail('no-at-sign')).toBeNull();
    expect(normalizeEmailGoogle(' J.O.E@Gmail.com')).toBe('joe@gmail.com');
    expect(normalizeEmailGoogle('j.o.e@example.com')).toBe('j.o.e@example.com');
    expect(await sha256Hex(normalizeEmailGoogle(' J.O.E@Gmail.com')!))
      .toBe('62b1ab5bc982e80ecf47618d6c3e96368906bbcd6bf3c82b0d872ba80329e363');
    expect(await sha256Hex(normalizeEmail('J.O.E@gmail.com')!))
      .toBe('32eb0a4c90c82fa16fdd4fd35787f97ec43da56ca6576ed8bdeacb490ffe551c');
  });
  it('normalizes phones to E.164', () => {
    expect(normalizePhone('(212) 555-0100')).toBe('+12125550100');
    expect(normalizePhone('+44 20 7946 0958')).toBe('+442079460958');
    expect(normalizePhone('0044 20 7946 0958', false)).toBe('442079460958');
    expect(normalizePhone('123')).toBeNull();
  });
  it('builds the event page url only for an https base', () => {
    expect(eventSourceUrl('https://exos.example/', { id: 'ev-1', slug: 'my show' })).toBe('https://exos.example/e/my%20show');
    expect(eventSourceUrl('https://exos.example', { id: 'ev-1' })).toBe('https://exos.example/event/ev-1');
    expect(eventSourceUrl('', { id: 'ev-1' })).toBeUndefined();
  });
  it('holds each platform to its event-age window', async () => {
    expect(tooOld(await row({ occurred_at: '2026-09-22T12:00:00Z' }), NOW)).toMatch(/older/);
    expect(tooOld(await row({ platform: 'ga4', occurred_at: '2026-09-27T11:00:00Z' }), NOW)).toMatch(/older/);
    expect(tooOld(await row({ platform: 'ga4', occurred_at: '2026-09-28T12:00:00Z' }), NOW)).toBeNull();
  });
});

describe('Meta Conversions API', () => {
  it('sends Purchase with the browser eventID, hashed em, fbp / fbc and value', async () => {
    const r = buildMeta(await row(), cred({ pixel_id: '123456789012345' }, { test_event_code: 'TEST1' }), CTX);
    expect(r.ok).toBe(true);
    if (!r.ok) throw new Error('meta skipped');
    expect(r.request.url).toBe(`https://graph.facebook.com/${META_GRAPH_VERSION}/123456789012345/events`);
    expect(r.request.url).not.toContain('SECRET');
    const body = r.request.body as any;
    expect(body.access_token).toBe('SECRET-token-123');
    expect(body.test_event_code).toBe('TEST1');
    const ev = body.data[0];
    expect(ev).toMatchObject({
      event_name: 'Purchase', event_id: 'cs_test_abc123', action_source: 'website',
      event_time: Math.floor(Date.parse('2026-09-30T11:00:00Z') / 1000),
      event_source_url: 'https://exos.example/e/ae-show',
    });
    expect(ev.user_data.em).toEqual([await sha256Hex('ae-buyer@x.com')]);
    expect(ev.user_data.fbp).toBe('fb.1.1690000000000.123456789');
    expect(ev.user_data.fbc).toBe(`fb.1.${Date.parse('2026-09-30T10:55:00Z')}.IwAR0abc`);
    expect(ev.user_data.client_ip_address).toBeUndefined();
    expect(ev.custom_data).toMatchObject({ value: 50, currency: 'USD', content_ids: ['ev-1'], num_items: 2, order_id: 'cs_test_abc123' });
  });
  it('prefers the _fbc cookie, and skips without a user agent or for refunds', async () => {
    expect(metaFbc(await row({}, { ad_ids: { fbc: 'fb.1.1.cookie' } }))).toBe('fb.1.1.cookie');
    expect(metaFbc(await row({}, { ad_ids: {} }))).toBeUndefined();
    expect(buildMeta(await row({}, { user_agent: undefined }), cred({ pixel_id: '123456789012345' }), CTX).ok).toBe(false);
    expect(buildMeta(await row({ event_name: 'Refund' }), cred({ pixel_id: '123456789012345' }), CTX).ok).toBe(false);
    expect(buildMeta(await row(), cred({}), CTX).ok).toBe(false);
  });
});

describe('TikTok Events API', () => {
  it('puts the token in the Access-Token header and ttclid on the user', async () => {
    const r = buildTikTok(await row({ platform: 'tiktok' }), cred({ pixel_code: 'C4ABCDEFGHIJKLMNOPQR' }), CTX);
    if (!r.ok) throw new Error((r as { skip: string }).skip);
    expect(r.request.url).toBe('https://business-api.tiktok.com/open_api/v1.3/event/track/');
    expect(r.request.headers['Access-Token']).toBe('SECRET-token-123');
    const body = r.request.body as any;
    expect(body).toMatchObject({ event_source: 'web', event_source_id: 'C4ABCDEFGHIJKLMNOPQR' });
    const ev = body.data[0];
    expect(ev).toMatchObject({ event: 'Purchase', event_id: 'cs_test_abc123', page: { url: 'https://exos.example/e/ae-show' } });
    expect(ev.user).toMatchObject({ ttclid: 'E.C.P.tt', email: await sha256Hex('ae-buyer@x.com') });
    expect(ev.properties).toMatchObject({
      value: 50, currency: 'USD', content_type: 'product', order_id: 'cs_test_abc123',
      contents: [{ content_id: 'ev-1', quantity: 2, price: 25 }],
    });
  });
  it('skips with nothing to match on', async () => {
    const r = buildTikTok(await row({ platform: 'tiktok' }, { em: undefined, ad_ids: {} }), cred({ pixel_code: 'C4ABCDEFGHIJKLMNOPQR' }), CTX);
    expect(r.ok).toBe(false);
  });
});

describe('GA4 Measurement Protocol', () => {
  it('sends purchase with client_id, transaction_id and Google-normalized email', async () => {
    const r = buildGa4(await row({ platform: 'ga4' }, { em_google: await sha256Hex('joe@gmail.com') }),
      cred({ measurement_id: 'G-ABC123XYZ' }), CTX);
    if (!r.ok) throw new Error((r as { skip: string }).skip);
    const u = new URL(r.request.url);
    expect(u.host).toBe('www.google-analytics.com');
    expect(u.searchParams.get('measurement_id')).toBe('G-ABC123XYZ');
    expect(u.searchParams.get('api_secret')).toBe('SECRET-token-123');
    const body = r.request.body as any;
    expect(body.client_id).toBe('123456789.1690000000');
    expect(body.timestamp_micros).toBe(Date.parse('2026-09-30T11:00:00Z') * 1000);
    expect(body.user_data.sha256_email_address).toEqual(['62b1ab5bc982e80ecf47618d6c3e96368906bbcd6bf3c82b0d872ba80329e363']);
    expect(body.events[0]).toEqual({
      name: 'purchase',
      params: { transaction_id: 'cs_test_abc123', value: 50, currency: 'USD',
        items: [{ item_id: 'ev-1', item_name: 'AE Show', quantity: 2, price: 25 }] },
    });
  });
  it('sends refund with the order transaction id and the refunded value', async () => {
    const r = buildGa4(await row({ platform: 'ga4', event_name: 'Refund', event_id_dedupe: 'refund:x', value_cents: 2000 }),
      cred({ measurement_id: 'G-ABC123XYZ' }), CTX);
    if (!r.ok) throw new Error((r as { skip: string }).skip);
    expect((r.request.body as any).events[0]).toEqual({
      name: 'refund', params: { transaction_id: 'cs_test_abc123', value: 20, currency: 'USD' },
    });
  });
  it('skips without a GA client id', async () => {
    expect(buildGa4(await row({ platform: 'ga4' }, { ad_ids: {} }), cred({ measurement_id: 'G-ABC123XYZ' }), CTX).ok).toBe(false);
  });
});

describe('Reddit, Snap, Google Ads', () => {
  it('Reddit: bearer token, rdt_cid click id, conversion_id = session id', async () => {
    const r = buildReddit(await row({ platform: 'reddit' }), cred({ pixel_id: 'a2_abc123' }), CTX);
    if (!r.ok) throw new Error((r as { skip: string }).skip);
    expect(r.request.url).toBe('https://ads-api.reddit.com/api/v3/pixels/a2_abc123/conversion_events');
    expect(r.request.headers.Authorization).toBe('Bearer SECRET-token-123');
    const ev = (r.request.body as any).data.events[0];
    expect(ev).toMatchObject({ click_id: 'rdt-1', action_source: 'WEBSITE', type: { tracking_type: 'Purchase' } });
    expect(ev.metadata).toMatchObject({ conversion_id: 'cs_test_abc123', value: 50, currency: 'USD', item_count: 2 });
  });
  it('Snap: PURCHASE with ScCid, validate endpoint in test mode', async () => {
    const pix = '0f0e0d0c-0b0a-4908-8706-050403020100';
    const r = buildSnap(await row({ platform: 'snap' }), cred({ pixel_id: pix }), CTX);
    if (!r.ok) throw new Error((r as { skip: string }).skip);
    expect(r.request.url).toBe(`https://tr.snapchat.com/v3/${pix}/events?access_token=SECRET-token-123`);
    const ev = (r.request.body as any).data[0];
    expect(ev).toMatchObject({ event_name: 'PURCHASE', event_id: 'cs_test_abc123', action_source: 'website' });
    expect(ev.user_data.sc_click_id).toBe('sc-1');
    expect(ev.custom_data).toMatchObject({ value: 50, currency: 'USD', order_id: 'cs_test_abc123' });
    const t = buildSnap(await row({ platform: 'snap' }), cred({ pixel_id: pix }, { test_event_code: 'T' }), CTX);
    expect(t.ok && t.request.url).toContain('/events/validate?');
  });
  it('Google Ads: Data Manager request with gclid, never the stored token', async () => {
    const r = buildGoogleAds(await row({ platform: 'google_ads' }),
      cred({ customer_id: '1234567890', conversion_action_id: '987654' }), CTX);
    if (!r.ok) throw new Error((r as { skip: string }).skip);
    expect(r.request.url).toBe('https://datamanager.googleapis.com/v1/events:ingest');
    expect(JSON.stringify(r.request)).not.toContain('SECRET');
    const body = r.request.body as any;
    expect(body.destinations[0]).toEqual({
      operatingAccount: { accountType: 'GOOGLE_ADS', accountId: '1234567890' }, productDestinationId: '987654',
    });
    expect(body.events[0]).toMatchObject({
      adIdentifiers: { gclid: 'Cj0KCQ' }, conversionValue: 50, currency: 'USD', transactionId: 'cs_test_abc123',
    });
    expect(plannedOnly('google_ads')).toBe(true);
    expect(plannedOnly('meta')).toBe(false);
  });
});

describe('send loop helpers', () => {
  it('redacts the secret from url, headers and body', async () => {
    const r = buildGa4(await row({ platform: 'ga4' }), cred({ measurement_id: 'G-ABC123XYZ' }), CTX);
    if (!r.ok) throw new Error((r as { skip: string }).skip);
    const red = redactRequest(r.request, 'SECRET-token-123');
    expect(JSON.stringify(red)).not.toContain('SECRET-token-123');
    expect(red.url).toContain('api_secret=[redacted]');
    // A secret that URL-encodes differently is caught in its encoded form too.
    const enc = redactRequest({ method: 'POST', url: 'https://x.test/?k=a%2Bb%2Fc%3D', headers: {}, body: {} }, 'a+b/c=');
    expect(enc.url).toBe('https://x.test/?k=[redacted]');
    const m = buildMeta(await row(), cred({ pixel_id: '123456789012345' }), CTX);
    if (!m.ok) throw new Error((m as { skip: string }).skip);
    expect((redactRequest(m.request, 'SECRET-token-123').body as any).access_token).toBe('[redacted]');
    expect(scrubSecret('bad token SECRET-token-123', 'SECRET-token-123')).toBe('bad token [redacted]');
  });
  it('dispatches by platform and refuses hosts outside the allowlist', async () => {
    expect(buildConversionRequest(await row({ platform: 'tiktok' }), cred({ pixel_code: 'C4ABCDEFGHIJKLMNOPQR' }), CTX).ok).toBe(true);
    const bad = buildConversionRequest(await row({ platform: 'nope' as any }), cred({}), CTX);
    expect(bad.ok).toBe(false);
  });
  it('sorts responses into sent / failed / retry and scrubs the error text', async () => {
    const req = { method: 'POST' as const, url: 'https://graph.facebook.com/x', headers: {}, body: {} };
    const ok = await sendConversion(req, 'SECRET-token-123', async () => new Response('{}', { status: 200 }));
    expect(ok).toEqual({ result: 'sent', status: 200 });
    const bad = await sendConversion(req, 'SECRET-token-123', async () => new Response('invalid token SECRET-token-123', { status: 400 }));
    expect(bad).toMatchObject({ result: 'failed', status: 400 });
    expect((bad as any).error).not.toContain('SECRET');
    expect((await sendConversion(req, 's', async () => new Response('', { status: 429 }))).result).toBe('retry');
    expect((await sendConversion(req, 's', async () => new Response('', { status: 503 }))).result).toBe('retry');
    expect((await sendConversion(req, 's', async () => { throw new Error('boom'); })).result).toBe('retry');
  });
});
