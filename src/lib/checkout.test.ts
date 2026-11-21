// startCheckout's refusals: the server's message, plus its reason code, so a
// guest whose code needs an account is sent to sign-in (review of #132, I5).
import { beforeEach, describe, expect, it, vi } from 'vitest';

const invoke = vi.fn();
vi.mock('./supabase', () => ({ supabase: { functions: { invoke: (...a: unknown[]) => invoke(...a) } } }));

import { CheckoutError, needsSignIn, startCheckout } from './checkout';

const refusal = (status: number, body: unknown) => ({
  data: null,
  error: { message: 'Edge Function returned a non-2xx status code', context: new Response(JSON.stringify(body), { status }) },
});
const input = { eventId: 'e1', tierId: 't1', quantity: 1, successUrl: 'https://x/s', cancelUrl: 'https://x/c', guestEmail: 'a@b.co', voucherCode: 'CODE' };

describe('startCheckout refusals', () => {
  beforeEach(() => invoke.mockReset());

  it("a guest's account-only code: reason sign_in, so the page opens sign-in", async () => {
    invoke.mockResolvedValue(refusal(401, { error: 'sign in to use this code', reason: 'sign_in' }));
    const err = await startCheckout(input).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(CheckoutError);
    expect((err as CheckoutError).message).toBe('sign in to use this code');
    expect(needsSignIn(err)).toBe(true);
  });

  it('any other refusal keeps its message and is not a sign-in prompt', async () => {
    invoke.mockResolvedValue(refusal(409, { error: 'sold out' }));
    const err = await startCheckout(input).catch((e: unknown) => e);
    expect((err as Error).message).toBe('sold out');
    expect(needsSignIn(err)).toBe(false);
    invoke.mockResolvedValue(refusal(401, { error: 'sign in to cover the rest', reason: 'group_host' }));
    expect(needsSignIn(await startCheckout(input).catch((e: unknown) => e))).toBe(false);
    invoke.mockResolvedValue({ data: null, error: { message: 'network down' } });
    const net = await startCheckout(input).catch((e: unknown) => e);
    expect((net as Error).message).toBe('network down');
    expect(needsSignIn(net)).toBe(false);
    expect(needsSignIn(new Error('sign_in'))).toBe(false);
  });
});
