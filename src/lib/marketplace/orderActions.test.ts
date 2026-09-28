import { describe, expect, it, vi } from 'vitest';

vi.mock('../supabase', () => ({ supabase: {} }));
const { marketplaceOrderActions } = await import('./linksApi');

const base = { status: 'needs_attention' as const, buyer_email: null, transfer_ids: [] as string[], handled_at: null };

describe('marketplaceOrderActions', () => {
  it('resend only with a buyer email and issued tickets', () => {
    expect(marketplaceOrderActions(base).resend).toBe(false);
    expect(marketplaceOrderActions({ ...base, buyer_email: 'b@x.com' }).resend).toBe(false);
    expect(marketplaceOrderActions({ ...base, status: 'fulfilled', buyer_email: 'b@x.com', transfer_ids: ['t1'] }).resend).toBe(true);
    expect(marketplaceOrderActions({ ...base, status: 'cancelled', buyer_email: 'b@x.com', transfer_ids: ['t1'] }).resend).toBe(false);
  });

  it('mark handled only while it needs attention and is not handled yet', () => {
    expect(marketplaceOrderActions(base).markHandled).toBe(true);
    expect(marketplaceOrderActions({ ...base, handled_at: '2026-09-28T00:00:00Z' }).markHandled).toBe(false);
    expect(marketplaceOrderActions({ ...base, status: 'fulfilled' }).markHandled).toBe(false);
  });
});
