// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({
  user: null as { uid: string; email: string; emailVerified: boolean } | null,
  openAuthModal: vi.fn(),
  status: vi.fn(),
  signup: vi.fn(),
  confirmCode: vi.fn(),
  join: vi.fn(),
  verify: vi.fn(),
}));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: h.user, openAuthModal: h.openAuthModal }) }));
vi.mock('../lib/dropList', async (orig) => ({
  ...(await orig<typeof import('../lib/dropList')>()),
  getDropStatus: h.status, dropSignup: h.signup, dropConfirmCode: h.confirmCode, dropJoin: h.join, dropLeaveMine: vi.fn(),
  dropVerifySms: h.verify,
}));

import DropListCTA from './DropListCTA';

const OPEN = {
  open: true, onSaleAt: new Date('2026-11-20T17:00:00Z'), listPresale: false, joined: false, sms: false, phoneHint: null,
  smsPending: false, pendingHint: null,
  emailConsentText: 'Email me once when tickets for Show from Org go on sale. I can leave this list at any time.',
  smsConsentText: 'Text me once at this number when tickets for Show from Org go on sale. Reply STOP to cancel.',
};

beforeEach(() => {
  h.user = null;
  h.status.mockReset().mockResolvedValue(OPEN);
  h.signup.mockReset().mockResolvedValue('check_email');
  h.confirmCode.mockReset().mockResolvedValue(true);
  h.join.mockReset().mockResolvedValue({ ...OPEN, joined: true, smsPending: true, pendingHint: '…0101' });
  h.verify.mockReset().mockResolvedValue({ verified: true, status: { ...OPEN, joined: true, sms: true, phoneHint: '…0101' } });
});
afterEach(cleanup);

describe('DropListCTA', () => {
  it('renders nothing when the list is closed (on sale, sold out, draft)', async () => {
    h.status.mockResolvedValue({ ...OPEN, open: false });
    const { container } = render(<DropListCTA eventId="e1" />);
    await waitFor(() => expect(h.status).toHaveBeenCalled());
    expect(container.querySelector('[data-drop-list]')).toBeNull();
  });

  it('guest: email + the stored consent words, then "check your email" and the code', async () => {
    render(<DropListCTA eventId="e1" attribution={{ promoter: 'dj_k', fbclid: 'zz' }} />);
    const email = await screen.findByLabelText('Email');
    expect(screen.getByText(OPEN.emailConsentText)).toBeTruthy();
    fireEvent.change(email, { target: { value: 'fan@x.com' } });
    fireEvent.click(screen.getByRole('button', { name: /notify me/i }));
    await screen.findByText(/check your email/i);
    expect(h.signup).toHaveBeenCalledWith('e1', 'fan@x.com', { promoter: 'dj_k' });
    fireEvent.change(screen.getByLabelText(/code from the email/i), { target: { value: '123 456' } });
    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));
    await screen.findByText(/you're on the list/i);
    expect(h.confirmCode).toHaveBeenCalledWith('e1', '123456');
  });

  it('signed in with a confirmed email: one click, texts behind their own checkbox and words', async () => {
    h.user = { uid: 'u1', email: 'fan@x.com', emailVerified: true };
    render(<DropListCTA eventId="e1" />);
    const box = await screen.findByLabelText(/also text me/i);
    expect(screen.queryByLabelText('Email')).toBeNull();
    fireEvent.click(box);
    fireEvent.change(screen.getByLabelText(/mobile number/i), { target: { value: '212 555 0101' } });
    expect(screen.getByText(OPEN.smsConsentText)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /notify me/i }));
    await screen.findByText(/you're on the list/i);
    expect(h.join).toHaveBeenCalledWith('e1', { sms: true, phone: '212 555 0101', source: null });
    // The number counts only after the texted code comes back.
    expect(screen.queryByText(/and text …0101/)).toBeNull();
    fireEvent.change(await screen.findByLabelText(/code from the text/i), { target: { value: '654 321' } });
    fireEvent.click(screen.getByRole('button', { name: /turn on the text/i }));
    await screen.findByText(/and text …0101/);
    expect(h.verify).toHaveBeenCalledWith('e1', '654321');
  });

  it('the event\'s signup limit is full: says try again, no "check your email"', async () => {
    h.signup.mockResolvedValue('try_again');
    render(<DropListCTA eventId="e1" />);
    fireEvent.change(await screen.findByLabelText('Email'), { target: { value: 'fan@x.com' } });
    fireEvent.click(screen.getByRole('button', { name: /notify me/i }));
    await screen.findByText(/try again in a minute/i);
    expect(screen.queryByText(/check your email/i)).toBeNull();
  });

  it('already joined: says so, with a way to leave', async () => {
    h.user = { uid: 'u1', email: 'fan@x.com', emailVerified: true };
    h.status.mockResolvedValue({ ...OPEN, joined: true });
    render(<DropListCTA eventId="e1" />);
    await screen.findByText(/you're on the list/i);
    expect(screen.getByRole('button', { name: /leave the list/i })).toBeTruthy();
  });
});
