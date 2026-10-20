import { afterEach, describe, expect, it, vi } from 'vitest';

const h = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('./supabase', () => ({ supabase: { rpc: h.rpc } }));

import { queueEmail } from './mail';

afterEach(() => vi.restoreAllMocks());

describe('queueEmail', () => {
  it('true only when the RPC queued (or already had) the mail', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    h.rpc.mockResolvedValueOnce({ data: 'mail-id', error: null });
    expect(await queueEmail({ template: 'org-invite', refId: 't1' })).toBe(true);
    expect(h.rpc).toHaveBeenLastCalledWith('exos_queue_mail', { p_template: 'org-invite', p_ref_id: 't1' });

    h.rpc.mockResolvedValueOnce({ data: null, error: { message: 'Invite not found or not authorized' } });
    expect(await queueEmail({ template: 'org-invite', refId: 't1' })).toBe(false);

    h.rpc.mockRejectedValueOnce(new Error('offline'));
    expect(await queueEmail({ template: 'org-invite', refId: 't1' })).toBe(false);
  });
});
