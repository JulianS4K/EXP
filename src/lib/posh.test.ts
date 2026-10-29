import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { capLine, parsePoshEventStatus, parsePoshStatus, poshWebhookUrl, unmatchedLabel } from './posh';

describe('posh', () => {
  it('builds the webhook URL only from a real token', () => {
    const t = 'ab'.repeat(32);
    expect(poshWebhookUrl('https://p.supabase.co/', t)).toBe(`https://p.supabase.co/functions/v1/exos-posh-webhook/${t}`);
    expect(poshWebhookUrl('https://p.supabase.co', 'short')).toBe('');
    expect(poshWebhookUrl('', t)).toBe('');
  });

  it('parses the integration status', () => {
    const st = parsePoshStatus({
      connected: true, status: 'active', hint: '1a2b', received: 4, can_manage: true, last_received_at: '2026-10-29T10:00:00Z',
      counts: { orders: 4, confirmed: 2, pending: 1, unmatched: 1, tickets: 5, oversold: 0 },
      links: [{ id: 'l1', posh_ref: 'pool-party', event_id: 'e1', event_name: 'Pool Party' }],
      unmatched: [{ id: 'o1', posh_event_name: null, posh_event_slug: null, posh_event_id: '651a', state: 'pending', quantity: 2 }],
    });
    expect(st.connected && st.canManage).toBe(true);
    expect(st.counts.unmatched).toBe(1);
    expect(st.links[0]).toMatchObject({ poshRef: 'pool-party', eventName: 'Pool Party' });
    expect(unmatchedLabel(st.unmatched[0])).toBe('Posh event 651a');
    expect(st.unmatched[0].state).toBe('pending');
    expect(parsePoshStatus(null)).toMatchObject({ connected: false, links: [], unmatched: [] });
  });

  it('parses the event area and says what the cap is', () => {
    const ev = parsePoshEventStatus({
      connected: true, can_manage: false,
      cap: { tier_id: 't1', tier_name: 'GA', cap: 10, sold_in_cap: 10, remaining: 0, oversold: 3, oversold_unacked: 3, uncovered: 0 },
      sales: { confirmed_orders: 3, confirmed_tickets: 13, pending_orders: 1, pending_tickets: 2 },
      orders: [{ id: 'o1', state: 'confirmed', quantity: 7, over_qty: 3, attention: 'oversold: 3 ticket(s) past the Posh cap of 10' }],
    });
    expect(ev.cap?.oversoldUnacked).toBe(3);
    expect(ev.sales.confirmedTickets).toBe(13);
    expect(capLine(ev.cap)).toBe('Posh may sell 10 GA tickets: 10 sold, 0 left. 3 sold past the cap.');
    expect(capLine(null)).toMatch(/^No Posh cap yet/);
    expect(parsePoshEventStatus({}).cap).toBeNull();
  });
});
