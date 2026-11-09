import { describe, expect, it } from 'vitest';
import { handlePosSales, PosSalesError, voidBody } from '../../supabase/functions/exos-api/posSales.ts';
import { ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
import { parsePage } from '../../supabase/functions/_shared/api/paging.ts';

const route = (id: string) => ROUTES.find((r) => r.id === id)!;
const EV = '3f6b2c1e-8a4d-4e2f-9b1a-7c5d0e9f2a14';
const ORD = '6a0e3c1d-2b4f-4c8e-9d7a-1f2e3d4c5b6a';

describe('door sales API (claude/exos-pos-walkup)', () => {
  it('reads the void body flat or wrapped', () => {
    expect(voidBody({ reason: ' wrong type ' })).toEqual({ reason: 'wrong type', drawer_id: null });
    expect(voidBody({ pos_order: { reason: 'dup sale', drawer_id: EV.toUpperCase() } })).toEqual({ reason: 'dup sale', drawer_id: EV });
    expect(() => voidBody({ reason: 'x' })).toThrow(PosSalesError);
    expect(() => voidBody({ reason: 'fine', drawer_id: 'nope' })).toThrow(/UUID/);
  });

  it('lists through the org-scoped core, paged', async () => {
    const calls: Array<[string, Record<string, unknown>]> = [];
    const sb = { rpc: (fn: string, args: Record<string, unknown>) => { calls.push([fn, args]); return Promise.resolve({ data: { total: 3, data: [{ id: ORD }] }, error: null }); } };
    const out = await handlePosSales(route('list-event-pos-orders'), {
      sb, orgId: 'org-1', cred: { kind: 'api_key', id: 'k1' }, params: { id: EV }, page: parsePage(new URLSearchParams('page=2&per_page=1')), body: {},
    }) as { data: unknown[]; meta: { total: number; total_pages: number } };
    expect(calls).toEqual([['_exos_api_pos_orders', { p_org: 'org-1', p_event: EV, p_limit: 1, p_offset: 1 }]]);
    expect(out.meta).toMatchObject({ total: 3, total_pages: 3 });
  });

  it('voids only with an organization API key; SQL refusals keep their meaning', async () => {
    const sb = { rpc: () => Promise.resolve({ data: null, error: { code: 'P0002', message: 'order not found' } }) };
    const c = { sb, orgId: 'org-1', params: { id: EV, order: ORD }, page: parsePage(new URLSearchParams()), body: { reason: 'wrong type' } };
    await expect(handlePosSales(route('void-event-pos-order'), { ...c, cred: { kind: 'pat', id: 't1' } }))
      .rejects.toMatchObject({ status: 403 });
    await expect(handlePosSales(route('void-event-pos-order'), { ...c, cred: { kind: 'api_key', id: 'k1' } }))
      .rejects.toMatchObject({ status: 404, message: 'order not found' });
    await expect(handlePosSales(route('void-event-pos-order'), { ...c, cred: { kind: 'api_key', id: 'k1' }, params: { id: 'bad', order: ORD } }))
      .rejects.toMatchObject({ status: 404 });
  });
});
