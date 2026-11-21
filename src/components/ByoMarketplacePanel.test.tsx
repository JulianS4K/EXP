// @vitest-environment jsdom
// "Your own marketplace accounts" (mig 20261121214500): every own-account
// marketplace with its seller-account status and a % input, the seats each
// ticket type gets at that % (floor, at least 1 above 0, skipped types with
// the reason), the floor at what already sold, always a dry run; saving calls
// the RPC, a % under what sold or on a network-ticked marketplace is stopped
// before it; the preview shows each request and says nothing was sent. The
// pure helpers are checked against the server's rule too.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';

const h = vi.hoisted(() => ({ setArgs: [] as unknown[][], previewArgs: [] as unknown[][], setFail: null as string | null }));
vi.mock('../lib/supabase', () => ({ supabase: {}, initialAuthUrl: '' }));
vi.mock('../lib/byoMarketplaces', async (orig) => {
  const real = await orig<typeof import('../lib/byoMarketplaces')>();
  return {
    ...real,
    loadByoView: async () => VIEW,
    setByoAllocation: async (...args: unknown[]) => {
      h.setArgs.push(args);
      if (h.setFail) throw new Error(h.setFail);
      return {};
    },
    previewByo: async (...args: unknown[]) => {
      h.previewArgs.push(args);
      return { dry_run: true, channels: PLAN };
    },
  };
});

import ByoMarketplacePanel from './ByoMarketplacePanel';
import { minPctFor, pctProblem, seatsFor, type ByoChannelPlan, type ByoView } from '../lib/byoMarketplaces';

const ORG = '11111111-1111-4111-8111-111111111111';
const EV = '22222222-2222-4222-8222-222222222222';

const tier = (over: Record<string, unknown> = {}) => ({
  tier_id: 't1', name: 'GA', capacity: 200, price: 40, allocated: 20, held: 8, sold: 0, min_pct: 0, status: 'pending',
  account: 'own', skip: null, listed: false, ...over,
});

const VIEW: ByoView = {
  event: { id: EV, org_id: ORG, name: 'Big Night', status: 'published', free_tier: false },
  dry_run: true,
  channels: [
    { channel: 'stubhub', provider: 'stubhub', own: true, pct: 10, min_pct: 1, connected: true, network_ticked: false,
      tiers: [tier({ sold: 2, min_pct: 1 }), tier({ tier_id: 't2', name: 'VIP', capacity: 7, price: 100 }),
              tier({ tier_id: 't3', name: 'Free', capacity: 50, price: 0, skip: 'a $0 ticket type is never offered on a resale marketplace' })] },
    { channel: 'seatgeek', provider: 'seatgeek', own: false, pct: 0, min_pct: 0, connected: false, network_ticked: true, tiers: [tier()] },
    { channel: 'vivid', provider: 'vivid', own: false, pct: 0, min_pct: 0, connected: false, network_ticked: false, tiers: [tier()] },
    { channel: 'evo', provider: 'tevo', own: false, pct: 0, min_pct: 0, connected: false, network_ticked: false, tiers: [tier()] },
  ] as never,
};

const PLAN: ByoChannelPlan[] = [{
  channel: 'stubhub', label: 'StubHub', pct: 10, connected: true, dryRun: true,
  result: { warnings: ['Free: a $0 ticket type is never offered on a resale marketplace.'] },
  steps: [{ op: 'listing.create', method: 'POST', path: '/events/123456/sellerlistings', live: false, body: { external_id: 'ex1', quantity: 4 } }],
}];

beforeEach(() => { h.setArgs = []; h.previewArgs = []; h.setFail = null; });
afterEach(cleanup);

describe('the rule (same as exos_byo_set_allocation)', () => {
  it('floor of capacity x %, at least 1 above 0; nothing at 0 or without a capacity', () => {
    expect(seatsFor(200, 10)).toBe(20);
    expect(seatsFor(7, 10)).toBe(1);
    expect(seatsFor(200, 0.5)).toBe(1);
    expect(seatsFor(200, 0)).toBe(0);
    expect(seatsFor(null, 50)).toBe(0);
  });
  it('the smallest % keeps what sold (ceil to the hundredth)', () => {
    expect(minPctFor(200, 2)).toBe(1);
    expect(minPctFor(300, 1)).toBe(0.34);
    expect(minPctFor(200, 0)).toBe(0);
  });
  it('a % is 0-100, never under what sold, never on a marketplace the Exos network sells', () => {
    expect(pctProblem({ min_pct: 1, network_ticked: false }, 0.5, 'StubHub')).toMatch(/already sold 1%/);
    expect(pctProblem({ min_pct: 0, network_ticked: false }, 101, 'StubHub')).toMatch(/0 to 100/);
    expect(pctProblem({ min_pct: 0, network_ticked: true }, 5, 'SeatGeek')).toMatch(/Distribution/);
    expect(pctProblem({ min_pct: 0, network_ticked: true }, 0, 'SeatGeek')).toBeNull();
    expect(pctProblem({ min_pct: 1, network_ticked: false }, 2, 'StubHub')).toBeNull();
  });
});

describe('ByoMarketplacePanel', () => {
  it('lists every own-account marketplace, always a dry run, with the seats each type gets', async () => {
    render(<ByoMarketplacePanel eventId={EV} orgId={ORG} />);
    const sh = await screen.findByTestId('byo-stubhub');
    expect(screen.getByText('Dry run')).toBeTruthy();
    expect(within(sh).getByText('Seller account connected')).toBeTruthy();
    expect(within(sh).getByText(/At least 1%/)).toBeTruthy();
    const rows = within(sh).getAllByRole('row');
    expect(rows[1].textContent).toContain('20');           // GA: 10% of 200
    expect(rows[2].textContent).toContain('1');            // VIP: floor(0.7) -> 1
    expect(rows[3].textContent).toContain('$0');           // Free: skipped, with the reason
    expect(within(screen.getByTestId('byo-seatgeek')).getByText(/Ticked under Distribution/)).toBeTruthy();
    expect(within(screen.getByTestId('byo-vivid')).getByText(/Not connected/)).toBeTruthy();
  });

  it('the seats follow the % as it is typed', async () => {
    render(<ByoMarketplacePanel eventId={EV} orgId={ORG} />);
    const sh = await screen.findByTestId('byo-stubhub');
    fireEvent.change(within(sh).getByLabelText('StubHub share (%)'), { target: { value: '25' } });
    expect(within(sh).getAllByRole('row')[1].textContent).toContain('50');
  });

  it('saves a share through the RPC; stops one under what sold before calling', async () => {
    render(<ByoMarketplacePanel eventId={EV} orgId={ORG} />);
    const sh = await screen.findByTestId('byo-stubhub');
    fireEvent.change(within(sh).getByLabelText('StubHub share (%)'), { target: { value: '0.5' } });
    fireEvent.click(within(sh).getByRole('button', { name: 'Save' }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/can't go lower/);
    expect(h.setArgs).toHaveLength(0);
    fireEvent.change(within(sh).getByLabelText('StubHub share (%)'), { target: { value: '15' } });
    fireEvent.click(within(sh).getByRole('button', { name: 'Save' }));
    await waitFor(() => expect(h.setArgs).toEqual([[EV, 'stubhub', 15]]));
    expect((await screen.findByRole('status')).textContent).toContain('StubHub: 15% saved.');
  });

  it('shows the server\'s refusal', async () => {
    h.setFail = 'StubHub sold 3 of GA already: the share can\'t go below 1.50%';
    render(<ByoMarketplacePanel eventId={EV} orgId={ORG} />);
    const sh = await screen.findByTestId('byo-stubhub');
    fireEvent.click(within(sh).getByRole('button', { name: 'Save' }));
    expect((await screen.findByRole('alert')).textContent).toContain('below 1.50%');
  });

  it('the preview lists each request and says nothing was sent', async () => {
    render(<ByoMarketplacePanel eventId={EV} orgId={ORG} />);
    await screen.findByTestId('byo-stubhub');
    fireEvent.click(screen.getByRole('button', { name: 'Preview what Exos would send' }));
    const plan = await screen.findByTestId('byo-plan');
    expect(h.previewArgs).toEqual([[ORG, EV]]);
    expect(plan.textContent).toContain('StubHub: 1 request planned; nothing sent.');
    expect(plan.textContent).toContain('POST /events/123456/sellerlistings');
    expect(plan.textContent).toContain('never offered');
  });
});
