// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({
  user: null as { uid: string; email: string } | null,
  openAuth: vi.fn(),
  toast: vi.fn(),
  checkVoucher: vi.fn(),
  checkGuestVoucher: vi.fn(),
}));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: h.user, openAuth: h.openAuth }) }));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../lib/vouchers', () => ({ checkVoucher: h.checkVoucher, checkGuestVoucher: h.checkGuestVoucher }));

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
  h.checkGuestVoucher.mockReset().mockResolvedValue({ ...valid, voucherId: null });
});
const signInRequired = { ...valid, valid: false, voucherId: null, discountPercent: null, reason: 'sign in required' };
afterEach(cleanup);

describe('VoucherField: guests apply promo codes (mig 20261121143700)', () => {
  it('checks a signed-out buyer\'s code on the guest path, no sign-in', async () => {
    const onApplied = vi.fn();
    render(<VoucherField eventId="e1" onApplied={onApplied} />);
    fireEvent.change(screen.getByLabelText(/promo or access code/i), { target: { value: 'early20' } });
    fireEvent.click(screen.getByRole('button', { name: /^apply$/i }));
    await waitFor(() => expect(h.checkGuestVoucher).toHaveBeenCalledWith('e1', 'early20'));
    await waitFor(() => expect(onApplied).toHaveBeenCalledWith(expect.objectContaining({ code: 'early20', discountPercent: 20, canBypass: false })));
    expect(h.openAuth).not.toHaveBeenCalled();
    expect(h.checkVoucher).not.toHaveBeenCalled();
  });

  it('asks a guest to sign in for a code the server keeps for accounts, then applies it', async () => {
    h.checkGuestVoucher.mockResolvedValue(signInRequired);
    const onApplied = vi.fn();
    const { rerender } = render(<VoucherField eventId="e1" onApplied={onApplied} />);
    fireEvent.change(screen.getByLabelText(/promo or access code/i), { target: { value: 'upgrade1' } });
    fireEvent.click(screen.getByRole('button', { name: /^apply$/i }));
    await waitFor(() => expect(h.openAuth).toHaveBeenCalledWith('code'));
    expect(onApplied).not.toHaveBeenCalled();
    h.user = { uid: 'u1', email: 'fan@x.com' };
    rerender(<VoucherField eventId="e1" email="fan@x.com" onApplied={onApplied} />);
    await waitFor(() => expect(h.checkVoucher).toHaveBeenCalledWith('e1', 'upgrade1', 'fan@x.com'));
    await waitFor(() => expect(onApplied).toHaveBeenCalledWith(expect.objectContaining({ code: 'upgrade1' })));
  });

  // Review of #132, S1: a check on load would spend every visitor's guest
  // attempt on a bad link (?code=DEADCODE) and fill the event's guest budget.
  it('never checks a guest\'s link code on load: it waits in the field for Apply', async () => {
    const onApplied = vi.fn();
    render(<VoucherField eventId="e1" onApplied={onApplied} initialCode="LINK20" />);
    await new Promise((r) => setTimeout(r, 20));
    expect(h.checkGuestVoucher).not.toHaveBeenCalled();
    expect(h.checkVoucher).not.toHaveBeenCalled();
    expect(h.openAuth).not.toHaveBeenCalled();
    expect((screen.getByLabelText(/promo or access code/i) as HTMLInputElement).value).toBe('LINK20');
    fireEvent.click(screen.getByRole('button', { name: /^apply$/i }));
    await waitFor(() => expect(h.checkGuestVoucher).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(onApplied).toHaveBeenCalled());
  });

  it('sends a guest whose tries are used up to sign in, not an error', async () => {
    h.checkGuestVoucher.mockResolvedValue({ ...signInRequired, reason: 'too many attempts' });
    render(<VoucherField eventId="e1" onApplied={vi.fn()} />);
    fireEvent.change(screen.getByLabelText(/promo or access code/i), { target: { value: 'early20' } });
    fireEvent.click(screen.getByRole('button', { name: /^apply$/i }));
    await waitFor(() => expect(h.openAuth).toHaveBeenCalledWith('code'));
    expect(h.toast).not.toHaveBeenCalledWith(expect.objectContaining({ kind: 'error' }));
  });

  it('checks a link code straight away when signed in', async () => {
    h.user = { uid: 'u1', email: 'fan@x.com' };
    render(<VoucherField eventId="e1" email="fan@x.com" onApplied={vi.fn()} initialCode="LINK20" />);
    await waitFor(() => expect(h.checkVoucher).toHaveBeenCalledWith('e1', 'LINK20', 'fan@x.com'));
    expect(h.checkGuestVoucher).not.toHaveBeenCalled();
  });
});
