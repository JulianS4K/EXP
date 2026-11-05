// Mistake simulations for the partner API's request handling (exos-api):
// what a developer or a partner gets back when they send something wrong.
// The database side is tests/exos/sim_partner.sql; fixes in mig
// 20261104130000 and supabase/functions/_shared/api/request.ts.
// Each `it` is one SIM-PARTNER-T<n> mistake.

import { describe, expect, it } from 'vitest';
import { MAX_BODY_BYTES, readCapped } from '../../../supabase/functions/_shared/api/body.ts';
import {
  idempotencyKeyOf, parseBodyText, PLATFORM_ROUTES, RequestError, rpcAnswer, userTokenMayCall,
} from '../../../supabase/functions/_shared/api/request.ts';
import { PagingError, pageEnvelope, parsePage, PER_PAGE_MAX } from '../../../supabase/functions/_shared/api/paging.ts';
import { allowedMethods, matchRoute, ROUTES } from '../../../supabase/functions/_shared/api/routes.ts';
import { bearerKind } from '../../../supabase/functions/_shared/api/credentials.ts';
import {
  opendatePage, orderFilters, ParamError, parseOrderItems, presentedPartnerKey, reservationAttrs, unwrapParams,
} from '../../../supabase/functions/_shared/partners/sales.ts';
import { signWebhook, verifyWebhook } from '../../../supabase/functions/_shared/webhookSign.ts';

const TIER = '8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f';

/** A body streamed in the given chunks, with an optional (possibly lying) Content-Length. */
function streamed(chunks: Uint8Array[], contentLength?: number): Request {
  let i = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(ctrl) {
      if (i >= chunks.length) { ctrl.close(); return; }
      ctrl.enqueue(chunks[i++]);
    },
  });
  const headers: Record<string, string> = {};
  if (contentLength !== undefined) headers['content-length'] = String(contentLength);
  return new Request('https://x/exos-api/v1/events', { method: 'POST', body, headers, duplex: 'half' } as RequestInit);
}

function status(fn: () => unknown): number | 'ok' {
  try {
    fn();
    return 'ok';
  } catch (e) {
    if (e instanceof RequestError) return e.status;
    if (e instanceof PagingError || e instanceof ParamError) return 400;
    throw e;
  }
}

describe('malformed requests', () => {
  it('SIM-PARTNER-T1 oversized bodies are refused however they are sent', async () => {
    const big = new Uint8Array(MAX_BODY_BYTES + 1).fill(97);
    // Declared too big: refused without reading.
    expect(await readCapped(streamed([big], big.byteLength), MAX_BODY_BYTES)).toBeNull();
    // A Content-Length that lies (says 10): counted as it streams.
    expect(await readCapped(streamed([big.subarray(0, 40_000), big.subarray(40_000)], 10), MAX_BODY_BYTES)).toBeNull();
    // Exactly the limit is fine.
    expect((await readCapped(streamed([big.subarray(1)]), MAX_BODY_BYTES))?.length).toBe(MAX_BODY_BYTES);
  });

  it('SIM-PARTNER-T2 an emoji split across two chunks decodes whole', async () => {
    const bytes = new TextEncoder().encode('{"name":"Fête 🎉"}');
    const cut = bytes.indexOf(0xf0) + 2; // inside the 4-byte emoji
    const text = await readCapped(streamed([bytes.subarray(0, cut), bytes.subarray(cut)]), MAX_BODY_BYTES);
    expect(parseBodyText('application/json', text!)).toEqual({ name: 'Fête 🎉' });
  });

  it('SIM-PARTNER-T3 malformed JSON, scalars and the wrong Content-Type', () => {
    expect(status(() => parseBodyText('application/json', '{"name": "x",}'))).toBe(400);
    expect(status(() => parseBodyText('application/json', 'null'))).toBe(400);
    expect(status(() => parseBodyText('application/json', '42'))).toBe(400);
    expect(status(() => parseBodyText('application/json', '"a string"'))).toBe(400);
    expect(status(() => parseBodyText('text/plain', '{"name":"x"}'))).toBe(415);
    expect(status(() => parseBodyText('multipart/form-data; boundary=x', '--x--'))).toBe(415);
    expect(status(() => parseBodyText('application/xml', '<event/>'))).toBe(415);
    // The partner contract (rails) takes any declared type, but still needs JSON or a form.
    expect(parseBodyText('text/plain', '{"name":"x"}', 'rails')).toEqual({ name: 'x' });
    expect(status(() => parseBodyText('text/plain', 'name=x', 'rails'))).toBe(400);
    // What does work: charset suffixes, no type at all, an empty body, a bare list (lineups).
    expect(parseBodyText('application/json; charset=utf-8', '{"a":1}')).toEqual({ a: 1 });
    expect(parseBodyText(null, '{"a":1}')).toEqual({ a: 1 });
    expect(parseBodyText('application/json', '   ')).toEqual({});
    expect(parseBodyText('application/json', '[{"artist_id":"x"}]')).toEqual([{ artist_id: 'x' }]);
  });

  it('SIM-PARTNER-T4 form-encoded bodies, flat and Rails-style, with unicode', () => {
    expect(parseBodyText('application/x-www-form-urlencoded', 'event%5Bname%5D=F%C3%AAte+%F0%9F%8E%89'))
      .toEqual({ name: 'Fête 🎉' });
    const r = parseBodyText('application/x-www-form-urlencoded',
      `ticket_reservation[order_items_attributes][0][ticket_type_id]=${TIER}&ticket_reservation[order_items_attributes][0][quantity]=2`, 'rails');
    expect(parseOrderItems(unwrapParams(r, 'ticket_reservation').order_items_attributes)).toEqual([{ ticket_type_id: TIER, quantity: 2 }]);
    // Prototype keys never land.
    const evil = parseBodyText('application/x-www-form-urlencoded', '__proto__[admin]=1&a[constructor][x]=1', 'rails');
    expect(({} as Record<string, unknown>).admin).toBeUndefined();
    expect(Object.keys(evil)).not.toContain('__proto__');
  });

  it('SIM-PARTNER-T5 quantities: 0, negative, decimal, huge, text, too many lines', () => {
    const line = (quantity: unknown) => [{ ticket_type_id: TIER, quantity }];
    for (const q of [0, -1, 1.5, '1.5', 101, 1e9, '1e2', 'lots', null, undefined, true]) {
      expect(status(() => parseOrderItems(line(q))), String(q)).toBe(400);
    }
    expect(parseOrderItems(line('7'))).toEqual([{ ticket_type_id: TIER, quantity: 7 }]);
    expect(parseOrderItems(line(100))[0].quantity).toBe(100);
    expect(parseOrderItems([{ ticket_type_id: TIER.toUpperCase(), quantity: 1 }])[0].ticket_type_id).toBe(TIER);
    expect(status(() => parseOrderItems(Array.from({ length: 11 }, () => ({ ticket_type_id: TIER, quantity: 1 }))))).toBe(400);
    expect(status(() => parseOrderItems([]))).toBe(400);
    expect(status(() => parseOrderItems([{ ticket_type_id: 'not-a-uuid', quantity: 1 }]))).toBe(400);
  });

  it('SIM-PARTNER-T6 attendee fields: emoji names count as characters; negative cash is refused', () => {
    // FIXED: 60 emoji are 120 UTF-16 units; the SQL CHECK counts 60 characters.
    expect(reservationAttrs({ first_name: '🎟'.repeat(60) }).first_name).toBe('🎟'.repeat(60));
    expect(status(() => reservationAttrs({ first_name: '🎟'.repeat(61) }))).toBe(400);
    expect(reservationAttrs({ last_name: 'Nguyễn 阮' }).last_name).toBe('Nguyễn 阮');
    expect(status(() => reservationAttrs({ cash_paid: -1 }))).toBe(400);
    expect(status(() => reservationAttrs({ cash_paid: 'NaN' }))).toBe(400);
    expect(reservationAttrs({ cash_paid: '54.10' }).cash_paid_cents).toBe(5410);
    expect(status(() => reservationAttrs({ email: 'not an email' }))).toBe(400);
    expect(status(() => reservationAttrs({ should_send_ticket_email: 'yes' }))).toBe(400);
  });
});

describe('retries and idempotency', () => {
  it('SIM-PARTNER-T7 a malformed Idempotency-Key is a 400, never a 500', () => {
    expect(idempotencyKeyOf(null)).toBeNull();
    expect(idempotencyKeyOf('order-2026-11-04-0001')).toBe('order-2026-11-04-0001');
    for (const bad of ['', 'short', 'has spaces in it', 'x'.repeat(101), 'ümlaut-key-001', 'a/b/c/d/e/f/g']) {
      expect(status(() => idempotencyKeyOf(bad)), bad).toBe(400);
    }
  });
});

describe('credentials and scopes', () => {
  it('SIM-PARTNER-T8 a partner key, a listing key or a typo is not an org credential', () => {
    expect(bearerKind('dk_live_' + 'a'.repeat(48))).toBeNull();
    expect(bearerKind('sh_live_' + 'a'.repeat(48))).toBeNull();
    expect(bearerKind('Bearer sk_live_x')).toBeNull();
    // and an org key is not a partner key on /public/… (it is only read from
    // shared_key / X-Shared-Key / Bearer, then must match dk_live_…).
    const q = new URLSearchParams({ shared_key: '  dk_live_abc  ' });
    expect(presentedPartnerKey(q, () => null)).toBe('dk_live_abc');
  });

  it('SIM-PARTNER-T9 a personal or OAuth token on a write that needs an org key is refused', () => {
    const writes = ROUTES.filter((r) => r.auth === 'api_key' && r.method !== 'GET');
    const orgKeyOnly = writes.filter((r) => !PLATFORM_ROUTES.has(r.id));
    expect(orgKeyOnly.length).toBeGreaterThan(50);
    for (const r of orgKeyOnly) {
      expect(userTokenMayCall('pat', r.method, r.id), r.id).toBe(false);
      expect(userTokenMayCall('oauth', r.method, r.id), r.id).toBe(false);
      expect(userTokenMayCall('api_key', r.method, r.id), r.id).toBe(true);
    }
    // Reads and the platform routes are open to user tokens.
    expect(userTokenMayCall('pat', 'GET', 'list-events')).toBe(true);
    expect(userTokenMayCall('oauth', 'POST', 'create-organizer-reservation')).toBe(true);
    // Every platform route id is a real route.
    const ids = new Set(ROUTES.map((r) => r.id));
    for (const id of PLATFORM_ROUTES) expect(ids.has(id), id).toBe(true);
  });

  it('SIM-PARTNER-T10 the wrong method on a real path is 405 with Allow, not 404', () => {
    expect(matchRoute('DELETE', '/events')).toBeNull();
    expect(allowedMethods('/events')).toEqual(expect.arrayContaining(['GET', 'POST']));
    expect(matchRoute('GET', '/events/not-a-uuid')).not.toBeNull(); // the handler answers 404 for a bad id
  });
});

describe('paging', () => {
  it('SIM-PARTNER-T11 per_page 0, 10000, negative or decimal is a 400; past the end is an empty page', () => {
    for (const per of ['0', '10000', '-1', '1.5', '', 'all', '201']) {
      expect(status(() => parsePage(new URLSearchParams({ per_page: per }))), per).toBe(400);
    }
    for (const page of ['0', '-2', '10001', 'last']) {
      expect(status(() => parsePage(new URLSearchParams({ page }))), page).toBe(400);
    }
    const p = parsePage(new URLSearchParams({ page: '99', per_page: '50' }));
    expect(p.from).toBe(4900);
    expect(pageEnvelope([], p, 30).meta).toEqual({ page: 99, per_page: 50, total: 30, total_pages: 1 });
    expect(parsePage(new URLSearchParams({ per_page: String(PER_PAGE_MAX) })).perPage).toBe(200);
  });

  it('SIM-PARTNER-T12 Opendate-style paging clamps instead (per_page up to 250, as Opendate does)', () => {
    expect(opendatePage(new URLSearchParams({ per_page: '10000' }))).toEqual({ page: 1, perPage: 250 });
    expect(status(() => opendatePage(new URLSearchParams({ per_page: '0' })))).toBe(400);
    expect(status(() => opendatePage(new URLSearchParams({ page: '-1' })))).toBe(400);
  });

  it('SIM-PARTNER-T13 mixing Opendate q[...] filters, Exos page/per_page and a cursor', () => {
    const q = new URLSearchParams('q[email_eq]=Fan@X.com&q[unknown_cont]=x&per_page=25&page=2&cursor=abc');
    // Filters: the known q[...] only (unknown ones are ignored, not an error).
    expect(orderFilters(q)).toEqual({ email: 'fan@x.com' });
    // Paging: page / per_page; there are no cursors, so `cursor` is ignored and
    // the answer carries no next cursor (a cursor loop stops after one page).
    expect(parsePage(q)).toMatchObject({ page: 2, perPage: 25 });
    expect(opendatePage(q)).toEqual({ page: 2, perPage: 25 });
    expect(status(() => orderFilters(new URLSearchParams('q[created_at_gteq]=yesterday')))).toBe(400);
  });
});

describe('error mapping', () => {
  it('SIM-PARTNER-T14 FIXED partner sold-out / not-on-sale / finished answer 409 / 422 / 409, not 500', () => {
    expect(rpcAnswer({ code: 'EXSLD', message: 'sold out: GA has 1 left' })).toEqual({
      status: 409, body: { error: 'sold out: GA has 1 left', reason: 'sold_out' },
    });
    expect(rpcAnswer({ code: 'EX422', message: 'ticket type x is not available for distribution' })?.status).toBe(422);
    expect(rpcAnswer({ code: 'EX422', message: 'x' })?.body.reason).toBe('not_available');
    expect(rpcAnswer({ code: 'EX409', message: 'this reservation was completed' })?.status).toBe(409);
    expect(rpcAnswer({ code: '22023', message: 'this Idempotency-Key was already used for another reservation' })?.status).toBe(400);
    expect(rpcAnswer({ code: 'P0002', message: 'reservation not found' })?.status).toBe(404);
    expect(rpcAnswer({ code: 'XX000', message: 'boom' })).toBeNull();
    expect(rpcAnswer(null)).toBeNull();
    // Long messages are cut (no stack dumps to partners).
    expect(String(rpcAnswer({ code: '22023', message: 'x'.repeat(1000) })?.body.error).length).toBe(300);
  });
});

describe('webhooks (receiver side)', () => {
  const secret = 'whsec_e9_test_secret';
  const body = JSON.stringify({ type: 'order.fulfilled', created_at: '2026-11-04T10:00:00Z', data: { id: 'cs_1' } });

  it('SIM-PARTNER-T15 a good signature verifies; a wrong secret or a changed body does not', async () => {
    const ts = '1793790000';
    const sig = await signWebhook(secret, ts, body);
    expect(sig).toMatch(/^sha256=[0-9a-f]{64}$/);
    expect(await verifyWebhook(secret, { timestamp: ts, signature: sig }, body, 1793790010)).toBe('ok');
    expect(await verifyWebhook('whsec_other', { timestamp: ts, signature: sig }, body, 1793790010)).toBe('bad_signature');
    expect(await verifyWebhook(secret, { timestamp: ts, signature: sig }, body.replace('cs_1', 'cs_2'), 1793790010)).toBe('bad_signature');
    // A common mistake: verifying JSON.stringify(JSON.parse(raw)) with other spacing.
    const reserialized = JSON.stringify(JSON.parse(body), null, 2);
    expect(await verifyWebhook(secret, { timestamp: ts, signature: sig }, reserialized, 1793790010)).toBe('bad_signature');
    // Another timestamp with the same signature (a spliced header) fails too.
    expect(await verifyWebhook(secret, { timestamp: '1793790001', signature: sig }, body, 1793790010)).toBe('bad_signature');
    expect(await verifyWebhook(secret, { timestamp: null, signature: sig }, body, 1793790010)).toBe('missing');
  });

  it('SIM-PARTNER-T16 a replayed old delivery is stale; duplicates dedupe on X-Exos-Delivery; order by created_at', async () => {
    const ts = '1793790000';
    const sig = await signWebhook(secret, ts, body);
    expect(await verifyWebhook(secret, { timestamp: ts, signature: sig }, body, 1793790000 + 3600)).toBe('stale');
    expect(await verifyWebhook(secret, { timestamp: ts, signature: sig }, body, 1793790000 + 299)).toBe('ok');
    // The receiver the docs describe: dedupe on the delivery id, and apply a
    // later created_at only (retries can arrive after a newer event).
    const seen = new Set<string>();
    const state: { at: string; status: string } = { at: '', status: 'none' };
    const receive = (delivery: string, payload: { created_at: string; type: string }) => {
      if (seen.has(delivery)) return 'duplicate';
      seen.add(delivery);
      if (payload.created_at <= state.at) return 'older';
      state.at = payload.created_at;
      state.status = payload.type;
      return 'applied';
    };
    expect(receive('d2', { created_at: '2026-11-04T10:05:00Z', type: 'order.refunded' })).toBe('applied');
    expect(receive('d1', { created_at: '2026-11-04T10:00:00Z', type: 'order.fulfilled' })).toBe('older');
    expect(receive('d2', { created_at: '2026-11-04T10:05:00Z', type: 'order.refunded' })).toBe('duplicate');
    expect(state.status).toBe('order.refunded');
  });
});
