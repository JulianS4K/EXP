import { beforeEach, describe, expect, it, vi } from 'vitest';

const { rpc } = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('./supabase', () => ({ supabase: { rpc } }));

import { claimFreeTickets } from './tickets';

beforeEach(() => rpc.mockReset().mockResolvedValue({ data: ['t1'], error: null }));

describe('claimFreeTickets', () => {
  it('sends the code that unlocked a hidden tier (mig 20261021100000)', async () => {
    await claimFreeTickets({ eventId: 'e1', tierId: 'hidden', quantity: 2, orderRef: 'r1', voucherCode: ' LIST ' });
    expect(rpc).toHaveBeenCalledWith('exos_claim_free_tickets', expect.objectContaining({
      p_tier_id: 'hidden', p_quantity: 2, p_order_ref: 'r1', p_voucher_code: 'LIST',
    }));
  });

  it('no code: the argument is left out', async () => {
    await claimFreeTickets({ eventId: 'e1', tierId: 'ga', voucherCode: '  ' });
    expect(rpc.mock.calls[0][1]).not.toHaveProperty('p_voucher_code');
  });
});
