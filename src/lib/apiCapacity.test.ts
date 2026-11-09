import { describe, it, expect } from 'vitest';
import {
  CapacityError, handleCapacity, poolBodyProblem, stepsBody, type CapacityCtx,
} from '../../supabase/functions/exos-api/capacity.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';

// exos-api/capacity.ts: every pool and price-step write sends the credential's
// API key to SQL (p_api_key), where its creator must be an owner or manager
// (migs 20261106120000 / 20261106130000); personal / OAuth tokens can't write.
const ORG = '0a000000-0000-4000-8000-000000000001';
const EV = '0a000000-0000-4000-8000-0000000000e1';
const POOL = '0a000000-0000-4000-8000-0000000000c1';
const TIER = '0a000000-0000-4000-8000-0000000000d1';
const KEY = '0a000000-0000-4000-8000-0000000000f1';

function ctx(over: Partial<CapacityCtx> = {}, error: { code: string; message: string } | null = null) {
  const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const sb = {
    rpc: async (fn: string, args: Record<string, unknown>) => {
      calls.push({ fn, args });
      return error ? { data: null, error } : { data: { ok: true }, error: null };
    },
  };
  const c = {
    sb, orgId: ORG, cred: { kind: 'api_key', id: KEY, userId: null, role: null },
    params: { id: EV, pool: POOL, tier: TIER }, body: {}, ...over,
  } as unknown as CapacityCtx;
  return { c, calls };
}
const route = (method: string, path: string) => matchRoute(method, path)!.route;

describe('exos-api capacity: the actor goes to SQL', () => {
  it('set-price-steps sends the API key', async () => {
    const { c, calls } = ctx({ body: { steps: [{ price_cents: 2000 }] } });
    await handleCapacity(route('PUT', `/events/${EV}/ticket-types/${TIER}/price-steps`), c);
    expect(calls).toEqual([{ fn: '_exos_api_price_steps_set', args: { p_org: ORG, p_api_key: KEY, p_event: EV, p_tier: TIER, p: { steps: [{ price_cents: 2000 }] } } }]);
  });
  it('pool create, update and delete send the API key', async () => {
    for (const [m, path, body] of [
      ['POST', `/events/${EV}/capacity-pools`, { name: 'Room', allocation: 500 }],
      ['PATCH', `/events/${EV}/capacity-pools/${POOL}`, { allocation: 450 }],
      ['DELETE', `/events/${EV}/capacity-pools/${POOL}`, {}],
    ] as const) {
      const { c, calls } = ctx({ body: { ...body } });
      await handleCapacity(route(m, path), c);
      expect(calls[0].fn).toBe('_exos_api_capacity_pool_write');
      expect(calls[0].args.p_api_key).toBe(KEY);
      expect(calls[0].args.p_org).toBe(ORG);
    }
  });
  it('a personal or OAuth token can\'t write (no SQL call)', async () => {
    for (const kind of ['pat', 'oauth'] as const) {
      const { c, calls } = ctx({ cred: { kind, id: KEY, userId: 'u1', role: 'owner' }, body: { steps: [] } });
      await expect(handleCapacity(route('PUT', `/events/${EV}/ticket-types/${TIER}/price-steps`), c)).rejects.toMatchObject({ status: 403 });
      expect(calls).toEqual([]);
    }
  });
  it('the SQL role refusal (42501) is a 403', async () => {
    const { c } = ctx({ body: { name: 'Room', allocation: 5 } },
      { code: '42501', message: 'only a key created by an organization owner or manager can do this' });
    const e = await handleCapacity(route('POST', `/events/${EV}/capacity-pools`), c).catch((x: unknown) => x) as CapacityError;
    expect(e).toBeInstanceOf(CapacityError);
    expect(e.status).toBe(403);
  });
  it('reads need no writer key (any events:read credential)', async () => {
    const { c, calls } = ctx({ cred: { kind: 'pat', id: KEY, userId: 'u1', role: 'finance' } });
    await handleCapacity(route('GET', `/events/${EV}/ticket-types/${TIER}/price-steps`), c);
    expect(calls).toEqual([{ fn: '_exos_api_price_steps', args: { p_org: ORG, p_event: EV, p_tier: TIER } }]);
  });
});

describe('exos-api capacity: bodies', () => {
  it('checks pool bodies before SQL', () => {
    expect(poolBodyProblem({ name: 'Room' }, true)).toMatch(/allocation is required/);
    expect(poolBodyProblem({ name: 'Room', allocation: null }, true)).toMatch(/0 or more/);
    expect(poolBodyProblem({ size: 1 }, false)).toMatch(/unknown field size/);
    expect(poolBodyProblem({ name: 'Room', allocation: 0 }, true)).toBeNull();
  });
  it('unwraps price-step bodies', () => {
    expect(stepsBody({ price_steps: { steps: [] } })).toEqual({ steps: [] });
    expect(stepsBody([{ price_cents: 1 }])).toEqual({ steps: [{ price_cents: 1 }] });
  });
});
