import { beforeEach, describe, expect, it, vi } from 'vitest';

const { invoke, refreshSession } = vi.hoisted(() => ({ invoke: vi.fn(), refreshSession: vi.fn() }));
vi.mock('./supabase', () => ({ supabase: { functions: { invoke }, auth: { refreshSession } } }));

import { claimFreeAsGuest, functionError, isSignInRequired, startCheckout } from './checkout';

// supabase-js FunctionsHttpError: the Response is on .context.
const httpError = (status: number, body: unknown) => ({
  message: 'Edge Function returned a non-2xx status code',
  context: { status, json: async () => body },
});

const base = { eventId: 'e1', tierId: 't1', quantity: 2, successUrl: 'https://x/ok', cancelUrl: 'https://x/no' };

beforeEach(() => {
  invoke.mockReset();
  refreshSession.mockReset();
});

describe('functionError', () => {
  it('reads payload.error, then payload.message, in fan words', async () => {
    expect((await functionError(httpError(409, { error: 'exos_create_hold: not enough tickets available' }), 'f')).message)
      .toMatch(/Not enough tickets left/);
    expect((await functionError(httpError(500, { message: 'internal thing broke' }), 'f')).message).toBe('Internal thing broke');
    expect((await functionError(httpError(500, 'not json'), 'Could not start checkout.')).message).toBe('Could not start checkout.');
  });

  it('a 401 asks for a sign-in', async () => {
    const e = await functionError(httpError(401, { message: 'Invalid JWT' }), 'f');
    expect(isSignInRequired(e)).toBe(true);
    expect(isSignInRequired(new Error('x'))).toBe(false);
  });
});

describe('startCheckout', () => {
  it('refreshes an expired session once and retries', async () => {
    invoke
      .mockResolvedValueOnce({ data: null, error: httpError(401, { message: 'Invalid JWT' }) })
      .mockResolvedValueOnce({ data: { url: 'https://stripe/pay' }, error: null });
    refreshSession.mockResolvedValue({ data: { session: { access_token: 'new' } }, error: null });
    await expect(startCheckout(base)).resolves.toBe('https://stripe/pay');
    expect(invoke).toHaveBeenCalledTimes(2);
  });

  it('no session to refresh: sign in (and the page resumes)', async () => {
    invoke.mockResolvedValue({ data: null, error: httpError(401, { error: 'unauthorized' }) });
    refreshSession.mockResolvedValue({ data: { session: null }, error: { message: 'no session' } });
    const err = await startCheckout(base).catch((e) => e);
    expect(isSignInRequired(err)).toBe(true);
    expect(invoke).toHaveBeenCalledTimes(1);
  });

  it('a guest is never refreshed', async () => {
    invoke.mockResolvedValue({ data: null, error: httpError(401, { error: 'sign in to use a code' }) });
    const err = await startCheckout({ ...base, guestEmail: 'a@b.co' }).catch((e) => e);
    expect(refreshSession).not.toHaveBeenCalled();
    expect(isSignInRequired(err)).toBe(true);
    expect(err.message).toBe('Sign in to use a code.');
  });

  it('shows the reason, not "non-2xx"', async () => {
    invoke.mockResolvedValue({ data: null, error: httpError(409, { error: 'exos_create_hold: sales have ended for this tier' }) });
    await expect(startCheckout(base)).rejects.toThrow('Sales for this ticket type have ended.');
  });
});

describe('claimFreeAsGuest', () => {
  it('sends the free add-ons with the claim', async () => {
    invoke.mockResolvedValue({ data: { free: true, issued: 2, email: 'a@b.co' }, error: null });
    await claimFreeAsGuest({ ...base, guestEmail: ' A@B.co ', addons: [{ addon_id: 'ad1', quantity: 1 }] });
    const body = invoke.mock.calls[0][1].body;
    expect(body.addons).toEqual([{ addon_id: 'ad1', quantity: 1 }]);
    expect(body.guest_email).toBe('a@b.co');
  });
  it('no add-ons: none sent', async () => {
    invoke.mockResolvedValue({ data: { free: true, issued: 1 }, error: null });
    await claimFreeAsGuest({ ...base, guestEmail: 'a@b.co', addons: [] });
    expect(invoke.mock.calls[0][1].body.addons).toBeUndefined();
  });
});
