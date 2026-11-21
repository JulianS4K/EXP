// POST /v1/orders/:id/adjustments (claude/exos-dice-leftovers, mig
// 20261108110000): the exos-api handler with a fake service-role client. The
// role and org rules are SQL's (tests/exos/test_dice_leftovers.sql DL2); this
// pins the route, the body and how each SQL answer maps to HTTP.
import { describe, expect, it } from 'vitest';
import {
  adjustmentBody, FEE_ADJ_CREATED, FEE_ADJ_ROUTES, FeeAdjError, handleFeeAdjustments, MAX_ADJUSTMENT_CENTS,
} from '../../supabase/functions/exos-api/feeAdjustments.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';
import { userTokenMayCall } from '../../supabase/functions/_shared/api/request.ts';

const ORG = 'aaaaaaaa-0000-4000-8000-000000000001';
const KEY = 'bbbbbbbb-0000-4000-8000-000000000002';
const page = { page: 1, perPage: 50, from: 0, to: 49 };

function fakeSb(answer: { data?: unknown; error?: { code?: string; message?: string } | null }) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  return {
    calls,
    // deno-lint-ignore no-explicit-any
    sb: { rpc: async (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return { data: answer.data ?? null, error: answer.error ?? null }; } } as any,
  };
}
const route = matchRoute('POST', '/orders/cs_live_1/adjustments')!.route;
const run = (sb: unknown, o: { body?: Record<string, unknown>; key?: string | null; kind?: 'api_key' | 'pat' | 'oauth'; id?: string } = {}) =>
  handleFeeAdjustments(route, {
    // deno-lint-ignore no-explicit-any
    sb: sb as any, orgId: ORG, params: { id: o.id ?? 'cs_live_1' }, page,
    cred: { kind: o.kind ?? 'api_key', id: KEY }, body: o.body ?? { fees_change_cents: -150, note: 'Goodwill' },
    idempotencyKey: o.key === undefined ? 'adj-0000-0001' : o.key,
  });
const status = async (p: Promise<unknown>) => {
  try { await p; return 0; } catch (e) { return e instanceof FeeAdjError ? e.status : -1; }
};

describe('POST /v1/orders/:id/adjustments', () => {
  it('is a finance:write route answered by the fee-adjustments module, 201', () => {
    expect(route).toMatchObject({ id: 'create-order-fee-adjustment', method: 'POST', scope: 'finance:write', auth: 'api_key' });
    expect(FEE_ADJ_ROUTES.has(route.id) && FEE_ADJ_CREATED.has(route.id)).toBe(true);
    // The GET on the same path is still the read.
    expect(matchRoute('GET', '/orders/cs_live_1/adjustments')!.route.id).toBe('get-order-fee-adjustments');
    // Personal and OAuth tokens never write here.
    expect(userTokenMayCall('pat', 'POST', route.id)).toBe(false);
    expect(userTokenMayCall('oauth', 'POST', route.id)).toBe(false);
  });
  it('reads the body: cents, a note, a ticket, the key (header or body, flat or wrapped)', () => {
    expect(adjustmentBody({ fees_change_cents: -150, note: '  Goodwill:   late doors ' }, 'adj-0000-0001'))
      .toEqual({ fees_change_cents: -150, note: 'Goodwill: late doors', ticket_id: null, idempotency_key: 'adj-0000-0001' });
    expect(adjustmentBody({ adjustment: { fees_change_cents: 25, note: 'Missed fee', ticket_id: 'AAAAAAAA-0000-4000-8000-000000000009', idempotency_key: 'body-key-01' } }, null))
      .toEqual({ fees_change_cents: 25, note: 'Missed fee', ticket_id: 'aaaaaaaa-0000-4000-8000-000000000009', idempotency_key: 'body-key-01' });
    for (const bad of [0, 1.5, '100', null, MAX_ADJUSTMENT_CENTS + 1, -MAX_ADJUSTMENT_CENTS - 1]) {
      expect(() => adjustmentBody({ fees_change_cents: bad, note: 'Goodwill' }, 'adj-0000-0001'), String(bad)).toThrow(FeeAdjError);
    }
    expect(() => adjustmentBody({ fees_change_cents: -1, note: 'x' }, 'adj-0000-0001')).toThrow(/note/);
    expect(() => adjustmentBody({ fees_change_cents: -1, note: 'Goodwill', ticket_id: 'nope' }, 'adj-0000-0001')).toThrow(/UUID/);
    expect(() => adjustmentBody({ fees_change_cents: -1, note: 'Goodwill' }, null)).toThrow(/idempotency key is required/);
    expect(() => adjustmentBody({ fees_change_cents: -1, note: 'Goodwill', idempotency_key: 'other-key-1' }, 'adj-0000-0001')).toThrow(/differ/);
    expect(() => adjustmentBody({ fees_change_cents: -1, note: 'Goodwill', idempotency_key: 'short' }, null)).toThrow(/8 to 200/);
  });
  it('calls the SQL core with the key, the org and the order from the path', async () => {
    const row = { id: 'r1', session_id: 'cs_live_1', event_id: 'e1', ticket_id: null, reason: 'manual', note: 'Goodwill',
      fees_change_cents: -150, currency: 'usd', refund_id: null, processed_at: '2026-11-08T19:00:00Z', actor: 'u', api_key_id: KEY,
      idempotency_key: 'adj-0000-0001', duplicate: false };
    const f = fakeSb({ data: row });
    const out = await run(f.sb) as { data: Record<string, unknown>; duplicate: boolean };
    expect(f.calls).toEqual([{ fn: '_exos_api_fee_adjustment', args: {
      p_org: ORG, p_api_key: KEY, p_session_id: 'cs_live_1', p_cents: -150, p_note: 'Goodwill', p_ticket_id: null, p_idem: 'adj-0000-0001',
    } }]);
    expect(out.duplicate).toBe(false);
    expect(out.data).toEqual({ id: 'r1', order_id: 'cs_live_1', event_id: 'e1', ticket_id: null, reason: 'manual', note: 'Goodwill',
      fees_change_cents: -150, currency: 'usd', refund_id: null, processed_at: '2026-11-08T19:00:00Z' });
    // A resend: the first row, duplicate.
    const again = await run(fakeSb({ data: { ...row, duplicate: true } }).sb) as { duplicate: boolean };
    expect(again.duplicate).toBe(true);
  });
  it("maps refusals: another org's order 404 (nothing echoed), a key whose creator may not 403, bad input 400", async () => {
    const other = fakeSb({ error: { code: 'P0002', message: 'order not found' } });
    let msg = '';
    try { await run(other.sb, { id: 'cs_other_org' }); } catch (e) { msg = (e as Error).message; expect((e as FeeAdjError).status).toBe(404); }
    expect(msg).toBe('order not found');
    expect(await status(run(fakeSb({ error: { code: '42501', message: 'only a key created by an organization owner or manager or finance can do this' } }).sb))).toBe(403);
    expect(await status(run(fakeSb({ error: { code: '22023', message: 'below zero' } }).sb))).toBe(400);
    expect(await status(run(fakeSb({ error: { code: '55000', message: 'only a placed order' } }).sb))).toBe(409);
    // A user token, or no key: refused before any SQL.
    const f = fakeSb({ data: {} });
    expect(await status(run(f.sb, { kind: 'pat' }))).toBe(403);
    expect(await status(run(f.sb, { key: null }))).toBe(400);
    expect(f.calls).toHaveLength(0);
  });
});
