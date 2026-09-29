// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({
  user: null as { uid: string; email: string } | null,
  openAuth: vi.fn(),
  toast: vi.fn(),
  checkVoucher: vi.fn(),
}));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: h.user, openAuth: h.openAuth }) }));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../lib/vouchers', () => ({ checkVoucher: h.checkVoucher }));

import VoucherField from './VoucherField';

const valid = {
  valid: true, voucherId: 'v1', restrictTierId: null, canBypass: false, overridePrice: null,
  discountPercent: 20, discountAmount: null, reason: null,
};

beforeEach(() => {
  h.user = null;
  h.openAuth.mockReset();
  h.toast.mockReset();
  h.checkVoucher.mockReset().mockResolvedValue(valid);
});
afterEach(cleanup);

describe('VoucherField: codes need an account', () => {
  it('asks a signed-out buyer to sign in instead of checking the code', () => {
    render(<VoucherField eventId="e1" onApplied={vi.fn()} />);
    fireEvent.change(screen.getByLabelText(/promo or access code/i), { target: { value: 'early20' } });
    fireEvent.click(screen.getByRole('button', { name: /sign in to apply/i }));
    expect(h.openAuth).toHaveBeenCalledWith('code');
    expect(h.checkVoucher).not.toHaveBeenCalled();
  });

  it('applies the waiting code once the buyer signs in', async () => {
    const onApplied = vi.fn();
    const { rerender } = render(<VoucherField eventId="e1" onApplied={onApplied} />);
    fireEvent.change(screen.getByLabelText(/promo or access code/i), { target: { value: 'early20' } });
    fireEvent.click(screen.getByRole('button', { name: /sign in to apply/i }));
    h.user = { uid: 'u1', email: 'fan@x.com' };
    rerender(<VoucherField eventId="e1" email="fan@x.com" onApplied={onApplied} />);
    await waitFor(() => expect(h.checkVoucher).toHaveBeenCalledWith('e1', 'early20', 'fan@x.com'));
    await waitFor(() => expect(onApplied).toHaveBeenCalledWith(expect.objectContaining({ code: 'early20', discountPercent: 20 })));
  });

  it('holds a link code for a signed-out buyer without prompting on load', () => {
    render(<VoucherField eventId="e1" onApplied={vi.fn()} initialCode="LINK20" />);
    expect(h.openAuth).not.toHaveBeenCalled();
    expect(h.checkVoucher).not.toHaveBeenCalled();
    expect((screen.getByLabelText(/promo or access code/i) as HTMLInputElement).value).toBe('LINK20');
  });

  it('checks a link code straight away when signed in', async () => {
    h.user = { uid: 'u1', email: 'fan@x.com' };
    render(<VoucherField eventId="e1" email="fan@x.com" onApplied={vi.fn()} initialCode="LINK20" />);
    await waitFor(() => expect(h.checkVoucher).toHaveBeenCalledWith('e1', 'LINK20', 'fan@x.com'));
  });
});
