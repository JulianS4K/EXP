// @vitest-environment jsdom
// Group pay v2 is paused (operator 2026-11-09, mig 20261111120000): a default
// build (no VITE_EXOS_GROUP_PAY) never shows the event page's "Pay separately"
// start, and both /group-pay routes show "Group pay isn't available" instead
// of their views. The smoke build sets VITE_EXOS_GROUP_PAY=on for its group-pay
// steps only (tests/smoke/run.sh), so this is what checks the default.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

vi.mock('../lib/supabase', () => ({ supabase: {} }));
import GroupPayGate from './GroupPayGate';
import GroupPayStart from './GroupPayStart';
import { ToastProvider } from '../context/ToastContext';
import { GROUP_PAY_OFF_TEXT, groupPayEnabled } from '../lib/groupPayFlag';

afterEach(() => {
  cleanup();
  vi.unstubAllEnvs();
});

// The two routes exactly as App.tsx declares them (checked below).
function at(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <ToastProvider>
        <Routes>
          <Route path="/group-pay/seat/:token" element={<GroupPayGate><p>seat view</p></GroupPayGate>} />
          <Route path="/group-pay/:groupId" element={<GroupPayGate><p>host view</p></GroupPayGate>} />
          <Route path="/event/:id" element={<GroupPayStart eventId="e1" tierId="t1" quantity={3} maxPerOrder={6} signedIn />} />
        </Routes>
      </ToastProvider>
    </MemoryRouter>,
  );
}

describe('group pay is off in a default build', () => {
  it('reads the flag: only "on" turns it on', () => {
    expect(groupPayEnabled()).toBe(false);
    expect(groupPayEnabled({})).toBe(false);
    for (const v of ['', 'off', 'true', '1', 'yes']) expect(groupPayEnabled({ VITE_EXOS_GROUP_PAY: v })).toBe(false);
    for (const v of ['on', 'ON', ' on ']) expect(groupPayEnabled({ VITE_EXOS_GROUP_PAY: v })).toBe(true);
  });

  it('hides the "Pay separately" start on the event page', () => {
    const { container } = at('/event/e1');
    expect(container.querySelector('[data-testid="group-pay-start"]')).toBeNull();
    expect(container.textContent).not.toMatch(/pay separately/i);
  });

  it('shows "not available" on the seat and host routes, never their views', () => {
    for (const path of ['/group-pay/seat/' + 'ab'.repeat(16), '/group-pay/c7e00000-0000-4000-8000-000000000001']) {
      const { container, unmount } = at(path);
      expect(screen.getByRole('heading', { name: GROUP_PAY_OFF_TEXT })).toBeTruthy();
      expect(container.textContent).not.toMatch(/seat view|host view/);
      // v1 is still offered.
      expect(container.textContent).toContain('Split with friends');
      unmount();
    }
  });

  it('App.tsx wraps both /group-pay routes in the gate', () => {
    const app = readFileSync(resolve(__dirname, '../App.tsx'), 'utf8');
    expect(app).toContain('<Route path="/group-pay/seat/:token" element={<GroupPayGate><GroupPaySeat /></GroupPayGate>} />');
    expect(app).toContain('<Route path="/group-pay/:groupId" element={<GroupPayGate><GroupPayHost /></GroupPayGate>} />');
    // v1 stays as it is.
    expect(app).toContain('<Route path="/split/:sessionId" element={<SplitWithFriends />} />');
  });
});

describe('with VITE_EXOS_GROUP_PAY=on (the smoke build of the group-pay steps)', () => {
  it('shows the start and the views', () => {
    vi.stubEnv('VITE_EXOS_GROUP_PAY', 'on');
    const ev = at('/event/e1');
    expect(ev.container.querySelector('[data-testid="group-pay-start"]')).not.toBeNull();
    ev.unmount();
    const seat = at('/group-pay/seat/' + 'ab'.repeat(16));
    expect(seat.container.textContent).toContain('seat view');
    expect(seat.container.textContent).not.toContain(GROUP_PAY_OFF_TEXT);
  });
});
