// @vitest-environment jsdom
// Social / "friends" features are paused (operator 2026-11-17, mig
// 20261117100000). A default build (no VITE_EXOS_SOCIAL) shows no way to start
// one: the group chat routes show "not available", /split shows it for an
// order with no split, the event editor's matched-seats panel is hidden unless
// a ticket type is already matched (and never offers "Sell as matched seats",
// "Match now" or "Reshuffle"), and the ticket's group card drops the quiz and
// "meet again". What already exists keeps working: an existing split's
// pay-back checklist, a type matched before the pause.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

const h = vi.hoisted(() => ({
  split: null as null | Record<string, unknown>,
  staffView: null as null | Record<string, unknown>,
  myGroup: { state: 'not_matched' } as Record<string, unknown>,
}));

vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: { uid: 'u-host' } }) }));
vi.mock('../lib/events', () => ({ getPublicEvent: () => Promise.resolve({ title: 'Fall Party' }) }));
vi.mock('../lib/split', async (orig) => {
  const real = await orig<typeof import('../lib/split')>();
  return {
    ...real,
    getSplit: () => Promise.resolve({
      sessionId: 'cs_1', eventId: 'e1', amountCents: 6000, quantity: 3, currency: 'usd',
      split: h.split,
      tickets: [
        { ticketId: 't1', tierName: 'GA', mine: true, pendingTransfer: !!h.split, status: 'active' },
        { ticketId: 't2', tierName: 'GA', mine: true, pendingTransfer: false, status: 'active' },
        { ticketId: 't3', tierName: 'GA', mine: true, pendingTransfer: false, status: 'active' },
      ],
      shares: h.split ? [{ id: 's1', ticketId: 't1', name: 'Fran', email: 'f@x.com', phone: null, amountCents: 2000, paid: false,
        nudgeCount: 0, transferStatus: null, claimPath: null }] : [],
    }),
  };
});
vi.mock('../lib/matchedSeatsApi', async (orig) => {
  const real = await orig<typeof import('../lib/matchedSeatsApi')>();
  return {
    ...real,
    getStaffViewOrNull: () => Promise.resolve(h.staffView),
    getMyGroup: () => Promise.resolve(h.myGroup),
  };
});

import SocialGate from './SocialGate';
import MatchedSeatsPanel from './MatchedSeatsPanel';
import TicketMatchedGroup from './TicketMatchedGroup';
import SplitWithFriends from '../views/SplitWithFriends';
import { ToastProvider } from '../context/ToastContext';
import { SOCIAL_OFF_TITLE, socialEnabled } from '../lib/socialFlag';
import type { Event } from '../types';

beforeEach(() => {
  h.split = null;
  h.staffView = null;
  h.myGroup = { state: 'not_matched' };
});
afterEach(() => {
  cleanup();
  vi.unstubAllEnvs();
});

function at(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <ToastProvider>
        <Routes>
          <Route path="/groups" element={<SocialGate feature="chat"><p>my groups view</p></SocialGate>} />
          <Route path="/groups/:groupId" element={<SocialGate feature="chat"><p>chat view</p></SocialGate>} />
          <Route path="/orgs/:orgId/groups" element={<SocialGate feature="chat"><p>org groups view</p></SocialGate>} />
          <Route path="/split/:sessionId" element={<SplitWithFriends />} />
        </Routes>
      </ToastProvider>
    </MemoryRouter>,
  );
}

const EVENT = { id: 'e1', title: 'Fall Party', ticketTiers: [{ id: 'd1', name: 'Seat' }, { id: 'd2', name: 'GA' }] } as unknown as Event;
const STAFF_VIEW = {
  config: { status: 'open', matchAt: null, revealAt: null, groupMin: 2, groupTarget: 4, groupMax: 6, groupCount: null,
    matchHoursBefore: 24, revealHoursBefore: 3, undersubPolicy: 'merge', quizEnabled: true, quizTags: [], quizLanguages: ['en'],
    retentionDays: 14, seed: null },
  holders: 3, answered: 1, spots: [], groups: [], leftovers: [], reports: [],
};

function panel() {
  return render(<ToastProvider><MatchedSeatsPanel event={EVENT} canManage /></ToastProvider>);
}

describe('social features are off in a default build', () => {
  it('reads the flag: only "on" turns it on', () => {
    expect(socialEnabled()).toBe(false);
    expect(socialEnabled({})).toBe(false);
    for (const v of ['', 'off', 'true', '1', 'yes']) expect(socialEnabled({ VITE_EXOS_SOCIAL: v })).toBe(false);
    for (const v of ['on', 'ON', ' on ']) expect(socialEnabled({ VITE_EXOS_SOCIAL: v })).toBe(true);
  });

  it('shows "not available" on the group chat routes, never their views', () => {
    for (const path of ['/groups', '/groups/c3000000-0000-0000-0000-000000000001', '/orgs/o1/groups']) {
      const { container, unmount } = at(path);
      expect(screen.getByRole('heading', { name: SOCIAL_OFF_TITLE.chat })).toBeTruthy();
      expect(container.textContent).not.toMatch(/groups view|chat view/);
      unmount();
    }
  });

  it('App.tsx wraps the three group chat routes in the gate', () => {
    const app = readFileSync(resolve(__dirname, '../App.tsx'), 'utf8');
    expect(app).toContain('<Route path="/orgs/:orgId/groups" element={<SocialGate feature="chat"><OrgGroups /></SocialGate>} />');
    expect(app).toContain('<Route path="/groups" element={<SocialGate feature="chat"><MyGroups /></SocialGate>} />');
    expect(app).toContain('<Route path="/groups/:groupId" element={<SocialGate feature="chat"><GroupChat /></SocialGate>} />');
  });

  it('/split: "not available" for an order with no split', async () => {
    at('/split/cs_1');
    await screen.findByRole('heading', { name: SOCIAL_OFF_TITLE.split });
    expect(screen.queryByText(/Split it|Add a friend|Send tickets/)).toBeNull();
  });

  it('/split: an existing split keeps its checklist, with no way to add friends', async () => {
    h.split = { venmoHandle: 'host', cashappTag: null, sendMode: 'on_paid', note: null };
    at('/split/cs_1');
    await screen.findByText("Who's paid");
    expect(screen.getByText('Fran')).toBeTruthy();
    expect(screen.getByRole('checkbox')).toBeTruthy();
    expect(screen.getByTestId('split-paused')).toBeTruthy();
    expect(screen.queryByText(/Add more friends|Add a friend/)).toBeNull();
  });

  it('the event editor panel is hidden when no ticket type is matched, and never offers to make one', async () => {
    const { container } = panel();
    const p = container.querySelector('[data-testid="matched-seats-panel"]') as HTMLElement;
    await waitFor(() => expect(p).toBeTruthy());
    expect(p.hidden).toBe(true);
    expect(container.textContent).not.toMatch(/Sell as matched seats/);
  });

  it('a type matched before the pause stays manageable, without Match now / Reshuffle', async () => {
    h.staffView = STAFF_VIEW;
    const { container } = panel();
    await screen.findAllByText('Save settings');
    const p = container.querySelector('[data-testid="matched-seats-panel"]') as HTMLElement;
    expect(p.hidden).toBe(false);
    expect(container.textContent).toMatch(/New matched ticket types are paused/);
    expect(container.textContent).not.toMatch(/Sell as matched seats|Match now|Reshuffle/);
  });

  it('the ticket card has no quiz while off', async () => {
    h.myGroup = { state: 'waiting', matchAt: null, revealAt: null, quizEnabled: true, quizTags: ['jazz'], quizLanguages: ['en'], answers: null };
    const { container } = render(<ToastProvider><TicketMatchedGroup ticketId="t1" /></ToastProvider>);
    await screen.findByText('Your group');
    expect(container.textContent).not.toMatch(/Help us seat you well|Delete my answers/);
  });
});

describe('with VITE_EXOS_SOCIAL=on', () => {
  beforeEach(() => vi.stubEnv('VITE_EXOS_SOCIAL', 'on'));

  it('shows the views, the split form, the panel and the quiz', async () => {
    const chat = at('/groups');
    expect(chat.container.textContent).toContain('my groups view');
    chat.unmount();

    const split = at('/split/cs_1');
    await screen.findByText('Split it');
    split.unmount();

    const { container, unmount } = panel();
    await screen.findAllByText('Sell as matched seats');
    expect((container.querySelector('[data-testid="matched-seats-panel"]') as HTMLElement).hidden).toBe(false);
    unmount();

    h.myGroup = { state: 'waiting', matchAt: null, revealAt: null, quizEnabled: true, quizTags: ['jazz'], quizLanguages: ['en'], answers: null };
    render(<ToastProvider><TicketMatchedGroup ticketId="t1" /></ToastProvider>);
    await screen.findByText(/Help us seat you well/);
  });
});
