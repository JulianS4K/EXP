import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import { guestVoucherCheck } from './vouchers';

describe('guestVoucherCheck (exos-checkout check_voucher answer)', () => {
  it('maps a valid guest code, never with a bypass', () => {
    expect(guestVoucherCheck({ is_valid: true, restrict_tier_id: 't1', can_bypass: true, override_price: null, discount_percent: '20', discount_amount: null }))
      .toEqual({ valid: true, voucherId: null, restrictTierId: 't1', canBypass: false, overridePrice: null, discountPercent: 20, discountAmount: null, reason: null });
  });
  it('keeps the server reason for a refusal and drops any grant', () => {
    expect(guestVoucherCheck({ is_valid: false, reason: 'sign in required', discount_percent: 50 }))
      .toMatchObject({ valid: false, reason: 'sign in required', discountPercent: null, canBypass: false });
    expect(guestVoucherCheck(null)).toMatchObject({ valid: false, reason: 'invalid code' });
  });
});
