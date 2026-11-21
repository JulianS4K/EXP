// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({ join: vi.fn(), poll: vi.fn(), rejoin: vi.fn(), challenge: vi.fn(), end: vi.fn() }));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
const auth = vi.hoisted(() => ({ user: null as { uid: string } | null, openAuthModal: vi.fn() }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => auth }));
vi.mock('../lib/waitingRoom', async (orig) => ({
  ...(await orig<typeof import('../lib/waitingRoom')>()),
  joinRoom: h.join, pollRoom: h.poll, rejoinRoom: h.rejoin, joinWithChallenge: h.challenge, endCheckout: h.end,
}));

import WaitingRoomGate from './WaitingRoomGate';
import { parseStatus } from '../lib/waitingRoom';

const BUY = <button type="button">Buy tickets</button>;

beforeEach(() => {
  h.join.mockReset();
  h.poll.mockReset();
  h.rejoin.mockReset();
  h.challenge.mockReset();
  document.head.querySelectorAll('script[src*="challenges.cloudflare.com"]').forEach((n) => n.remove());
  delete (window as unknown as { turnstile?: unknown }).turnstile;
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
});

describe('WaitingRoomGate', () => {
  it('no room: the buy box as usual, and no polling', async () => {
    vi.useFakeTimers();
    h.join.mockResolvedValue(parseStatus({ state: 'off' }));
    render(<WaitingRoomGate eventId="e1">{BUY}</WaitingRoomGate>);
    await act(async () => { await Promise.resolve(); });
    expect(screen.getByRole('button', { name: 'Buy tickets' })).toBeTruthy();
    await act(async () => { vi.advanceTimersByTime(600000); });
    expect(h.join).toHaveBeenCalledTimes(1);
    expect(h.poll).not.toHaveBeenCalled();
  });

  it('a failing check never blocks the page (checkout enforces the line itself)', async () => {
    h.join.mockRejectedValue(new Error('function not found'));
    render(<WaitingRoomGate eventId="e1">{BUY}</WaitingRoomGate>);
    await waitFor(() => expect(h.join).toHaveBeenCalled());
    expect(screen.getByRole('button', { name: 'Buy tickets' })).toBeTruthy();
  });

  it('in line: the queue replaces the buy box, polls on the server pace, then lets the buyer in', async () => {
    vi.useFakeTimers();
    h.join.mockResolvedValue(parseStatus({ state: 'waiting', position: 120, ahead: 119, eta_minutes: 2, poll_after_ms: 5000 }));
    h.poll.mockResolvedValueOnce(parseStatus({ state: 'waiting', position: 12, ahead: 11, eta_minutes: 1, poll_after_ms: 5000 }))
      .mockResolvedValueOnce(parseStatus({ state: 'admitted', admitted_until: '2026-11-20T17:10:00Z', poll_after_ms: 60000 }));
    render(<WaitingRoomGate eventId="e1">{BUY}</WaitingRoomGate>);
    await act(async () => { await Promise.resolve(); });
    expect(screen.getByRole('heading', { name: "You're number 120 in line" })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Buy tickets' })).toBeNull();
    expect(screen.getByRole('status').getAttribute('aria-live')).toBe('polite');
    await act(async () => { vi.advanceTimersByTime(6300); await Promise.resolve(); });
    expect(h.poll).toHaveBeenCalledTimes(1);
    expect(screen.getByRole('heading', { name: "You're number 12 in line" })).toBeTruthy();
    await act(async () => { vi.advanceTimersByTime(6300); await Promise.resolve(); });
    expect(screen.getByRole('button', { name: 'Buy tickets' })).toBeTruthy();
    expect(screen.getByText(/It's your turn/)).toBeTruthy();
  });

  it('lobby before the on-sale explains the random draw; a lapsed turn can join again', async () => {
    h.join.mockResolvedValue(parseStatus({ state: 'lobby', on_sale_at: '2026-11-20T17:00:00Z', poll_after_ms: 30000 }));
    const { unmount } = render(<WaitingRoomGate eventId="e1">{BUY}</WaitingRoomGate>);
    expect(await screen.findByRole('heading', { name: "You're in the waiting room" })).toBeTruthy();
    expect(screen.getByText(/random place in line/)).toBeTruthy();
    unmount();
    h.join.mockResolvedValue(parseStatus({ state: 'expired' }));
    h.rejoin.mockResolvedValue(parseStatus({ state: 'waiting', position: 900, ahead: 899, eta_minutes: 5 }));
    render(<WaitingRoomGate eventId="e1">{BUY}</WaitingRoomGate>);
    fireEvent.click(await screen.findByRole('button', { name: 'Join the line again' }));
    expect(await screen.findByRole('heading', { name: "You're number 900 in line" })).toBeTruthy();
  });

  it('Turnstile: no site key, no script and a plain note; never on a room without the check', async () => {
    h.join.mockResolvedValue(parseStatus({ state: 'challenge' }));
    render(<WaitingRoomGate eventId="e1" siteKey="">{BUY}</WaitingRoomGate>);
    expect(await screen.findByText(/can't take new places/)).toBeTruthy();
    expect(document.querySelector('script[src*="challenges.cloudflare.com"]')).toBeNull();
    cleanup();
    h.join.mockResolvedValue(parseStatus({ state: 'waiting', position: 5, ahead: 4, eta_minutes: 1 }));
    render(<WaitingRoomGate eventId="e1" siteKey="site-key">{BUY}</WaitingRoomGate>);
    await screen.findByRole('heading', { name: "You're number 5 in line" });
    expect(document.querySelector('script[src*="challenges.cloudflare.com"]')).toBeNull();
  });

  it('Turnstile: with a site key the widget renders (action wroom) and its token joins through exos-wroom-join', async () => {
    const render0 = vi.fn((_el: HTMLElement, o: Record<string, unknown>) => { (o.callback as (t: string) => void)('cf-token'); return 'w1'; });
    (window as unknown as { turnstile?: unknown }).turnstile = { render: render0 };
    h.join.mockResolvedValue(parseStatus({ state: 'challenge' }));
    h.challenge.mockResolvedValue(parseStatus({ state: 'waiting', position: 42, ahead: 41, eta_minutes: 1 }));
    render(<WaitingRoomGate eventId="e1" siteKey="site-key">{BUY}</WaitingRoomGate>);
    expect(await screen.findByRole('heading', { name: "You're number 42 in line" })).toBeTruthy();
    expect(render0.mock.calls[0][1]).toMatchObject({ sitekey: 'site-key', action: 'wroom' });
    expect(h.challenge).toHaveBeenCalledWith('e1', 'cf-token');
  });

  it('Turnstile: the script is loaded only when the check is shown', async () => {
    h.join.mockResolvedValue(parseStatus({ state: 'challenge' }));
    render(<WaitingRoomGate eventId="e1" siteKey="site-key">{BUY}</WaitingRoomGate>);
    await screen.findByRole('heading', { name: 'One quick check' });
    await waitFor(() => expect(document.querySelector('script[src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"]')).toBeTruthy());
    expect(screen.queryByRole('button', { name: 'Buy tickets' })).toBeNull();
  });

  it('a full guest line offers sign-in when signed out; signed in, no such button (a seat, or "we\'ll keep trying")', async () => {
    h.join.mockResolvedValue(parseStatus({ state: 'full', reason: 'room' }));
    render(<WaitingRoomGate eventId="e1" siteKey="">{BUY}</WaitingRoomGate>);
    fireEvent.click(await screen.findByRole('button', { name: 'Sign in to get a place' }));
    expect(auth.openAuthModal).toHaveBeenCalled();
    cleanup();
    auth.user = { uid: 'u1' };
    h.join.mockResolvedValue(parseStatus({ state: 'waiting', position: 20001, ahead: 10000, position_capped: true, kind: 'account' }));
    render(<WaitingRoomGate eventId="e1" siteKey="">{BUY}</WaitingRoomGate>);
    expect(await screen.findByRole('heading', { name: "You're number 10,000+ in line" })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Sign in to get a place' })).toBeNull();
    // Signed in, the guest line full (a new account): "we'll keep trying", no sign-in button.
    cleanup();
    h.join.mockResolvedValue(parseStatus({ state: 'full', reason: 'room', signed_in: true }));
    render(<WaitingRoomGate eventId="e1" siteKey="">{BUY}</WaitingRoomGate>);
    expect(await screen.findByRole('heading', { name: 'The line is full right now' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Sign in to get a place' })).toBeNull();
    auth.user = null;
  });

  it('a lapsed turn with its Stripe page still open: cancel it, then join again; a page being paid keeps the place', async () => {
    auth.user = { uid: 'u1' };
    h.join.mockResolvedValue(parseStatus({ state: 'checking_out', stripe: true, signed_in: true }));
    h.end.mockResolvedValue('in_use');
    render(<WaitingRoomGate eventId="e1" siteKey="">{BUY}</WaitingRoomGate>);
    expect(await screen.findByRole('heading', { name: 'Your last checkout is still open' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Buy tickets' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel that payment page and join again' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/being paid/);
    h.end.mockResolvedValue('ended');
    h.join.mockResolvedValue(parseStatus({ state: 'waiting', position: 12, ahead: 11, kind: 'account', signed_in: true }));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel that payment page and join again' }));
    expect(await screen.findByRole('heading', { name: "You're number 12 in line" })).toBeTruthy();
    expect(h.end).toHaveBeenCalledWith('e1');
    auth.user = null;
  });
});
