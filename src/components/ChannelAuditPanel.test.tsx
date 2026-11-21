// @vitest-environment jsdom
// "What we'd send" (channel core, mig 20261121162400): the planned writes per
// channel with their payload, the limit warnings they met, and "would use N
// of M" from the usage summary; hidden with nothing planned. Plus the limit
// notes the allocation grid shows.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({ rows: [] as any[], usage: [] as any[], fail: false }));
vi.mock('../lib/supabase', () => ({ supabase: {}, initialAuthUrl: '' }));
vi.mock('../lib/channelAudit', async (orig) => {
  const real = await orig<typeof import('../lib/channelAudit')>();
  return {
    ...real,
    fetchPlannedWrites: async () => { if (h.fail) throw new Error('rls'); return h.rows; },
    fetchUsageSummary: async () => h.usage,
  };
});

import ChannelAuditPanel from './ChannelAuditPanel';
import ChannelLimitNotes, { blockedOn } from './ChannelLimitNotes';
import { groupPlanned, payloadText, usageMeters, type ChannelAuditRow } from '../lib/channelAudit';

const ORG = '11111111-1111-4111-8111-111111111111';
const row = (over: Partial<ChannelAuditRow>): ChannelAuditRow => ({
  id: crypto.randomUUID(), channel: 'luma', op: 'event.create', method: 'POST', path: '/v1/event/create', live: false,
  request: { headers: { 'x-luma-api-key': '[redacted]' }, body: { name: 'Mirror Night', capacity: 40 } },
  response: { stand_in: true }, status: null, ok: true, error: null, warnings: null, event_id: null,
  at: '2026-11-21T12:00:00Z', ...over,
});

beforeEach(() => {
  h.rows = [];
  h.usage = [];
  h.fail = false;
});
afterEach(cleanup);

describe('ChannelAuditPanel', () => {
  it('stays hidden with nothing planned, and when the read is refused', async () => {
    const { container } = render(<ChannelAuditPanel orgId={ORG} />);
    await new Promise((r) => setTimeout(r, 20));
    expect(container.innerHTML).toBe('');
    h.fail = true;
    const again = render(<ChannelAuditPanel orgId={ORG} />);
    await new Promise((r) => setTimeout(r, 20));
    expect(again.container.innerHTML).toBe('');
  });

  it('lists planned writes per channel and shows the payload it would send', async () => {
    h.rows = [
      row({ channel: 'luma', at: '2026-11-21T12:00:00Z' }),
      row({ channel: 'eventbrite', op: 'ticket_class.create', path: '/v3/events/1/ticket_classes/', at: '2026-11-21T13:00:00Z',
            request: { body: { ticket_class: { name: 'GA', quantity_total: 20 } } } }),
      row({ channel: 'luma', method: 'GET', path: '/v1/event/get', op: 'read' }),
      row({ channel: 'stubhub', op: 'listing.create', path: '/listings', error: 'LIMIT_BLOCKED',
            warnings: [{ ruleId: 'stubhub_no_free_tiers', action: 'block', reason: 'StubHub is a resale marketplace: a $0 ticket type is never offered there.' }] }),
    ];
    render(<ChannelAuditPanel orgId={ORG} />);
    await screen.findByTestId('channel-audit-panel');
    expect(screen.getByRole('heading', { name: /what we.d send/i })).toBeTruthy();
    expect(screen.getAllByTestId('planned-write')).toHaveLength(3);
    const headings = screen.getAllByRole('heading', { level: 3 }).map((x) => x.textContent);
    expect(headings).toEqual(['Eventbrite', 'Luma', 'StubHub']);
    expect(screen.queryByText('/v1/event/get')).toBeNull();
    expect(screen.getByText(/a rule refuses it|platform rule refuses/i)).toBeTruthy();
    expect(screen.getByRole('note').textContent).toMatch(/\$0 ticket type is never offered/);
    const buttons = screen.getAllByRole('button', { name: /show the payload/i });
    fireEvent.click(buttons[0]);
    await waitFor(() => expect(screen.getByText(/quantity_total/)).toBeTruthy());
    expect(buttons[0].getAttribute('aria-expanded')).toBe('true');
    expect(document.body.textContent).not.toMatch(/x-luma-api-key.*[A-Za-z0-9]{20}/);
  });

  it('shows how much of a platform limit the plans would use', async () => {
    h.usage = [{ platform: 'luma', metric: 'sends', scope_key: 'cal-1', live_day: 0, planned_day: 0, live_week: 10, planned_week: 4, live_year: 10, planned_year: 4 }];
    render(<ChannelAuditPanel orgId={ORG} />);
    const list = await screen.findByRole('list', { name: /platform limits/i });
    expect(list.textContent).toMatch(/Luma \(cal-1\):.*would use 14 of 15 sends this week \(10 used, 4 planned\)/);
  });
});

describe('the helpers', () => {
  it('groups only planned writes, newest channel first; caps the payload text', () => {
    const g = groupPlanned([row({ channel: 'a_x', at: '2026-01-01T00:00:00Z' }), row({ channel: 'b_y', at: '2026-02-01T00:00:00Z' }), row({ live: true })]);
    expect(g.map((x) => x.channel)).toEqual(['b_y', 'a_x']);
    expect(payloadText(row({ request: { body: { s: 'x'.repeat(100) } } }), 20)).toMatch(/more characters/);
  });

  it('meters use the lower bound unless the account is known to be unlocked', () => {
    const s = [{ platform: 'luma', metric: 'sends', scope_key: '', live_day: 0, planned_day: 0, live_week: 20, planned_week: 0, live_year: 20, planned_year: 0 }];
    expect(usageMeters(s)[0].threshold).toBe(15);
    expect(usageMeters(s, { luma: { accountLevel: 'unlocked' } })[0].threshold).toBe(500);
    expect(usageMeters([{ ...s[0], platform: 'nowhere' }])).toEqual([]);
  });
});

describe('ChannelLimitNotes', () => {
  it('shows a block, a cap and a warning with their reasons', () => {
    render(<>
      <ChannelLimitNotes platform="stubhub" facts={{ priceCents: 0 }} label="GA" />
      <ChannelLimitNotes platform="meetup" facts={{ attendees: 40 }} />
      <ChannelLimitNotes platform="google_events" facts={{ free: true, hidden: true }} />
      <ChannelLimitNotes platform="seatgeek" facts={{ priceCents: 2500 }} />
    </>);
    const notes = screen.getAllByRole('note');
    expect(notes.map((n) => n.getAttribute('data-action'))).toEqual(['block', 'cap', 'warn']);
    expect(notes[0].textContent).toMatch(/^GA: StubHub is a resale marketplace/);
    expect(notes[1].textContent).toMatch(/Standard or Pro/);
    expect(blockedOn(['stubhub', 'seatgeek', 'luma'], { priceCents: 0 })).toEqual(['stubhub', 'seatgeek']);
  });
});
