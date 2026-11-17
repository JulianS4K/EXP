// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({ join: vi.fn(), poll: vi.fn(), rejoin: vi.fn() }));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../lib/waitingRoom', async (orig) => ({
  ...(await orig<typeof import('../lib/waitingRoom')>()),
  joinRoom: h.join, pollRoom: h.poll, rejoinRoom: h.rejoin,
}));

import WaitingRoomGate from './WaitingRoomGate';
import { parseStatus } from '../lib/waitingRoom';

const BUY = <button type="button">Buy tickets</button>;

beforeEach(() => {
  h.join.mockReset();
  h.poll.mockReset();
  h.rejoin.mockReset();
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
});
