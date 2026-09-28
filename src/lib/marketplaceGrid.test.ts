import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { sameOnAll } from '../components/ChannelLinks';
import { MARKETPLACE_NETWORKS, SHOW_MARKETPLACES } from './tierType';

describe('marketplace seats per ticket type', () => {
  it('"Same on all" sets one ticket type on every marketplace and leaves the others alone', () => {
    const draft = { 'stubhub:ga': '8', 'stubhub:vip': '0', 'seatgeek:vip': '2' };
    const next = sameOnAll(draft, ['stubhub', 'seatgeek', 'vivid'], 'ga', '8');
    expect(next).toEqual({ 'stubhub:ga': '8', 'seatgeek:ga': '8', 'vivid:ga': '8', 'stubhub:vip': '0', 'seatgeek:vip': '2' });
    expect(draft).toEqual({ 'stubhub:ga': '8', 'stubhub:vip': '0', 'seatgeek:vip': '2' });
  });

  it('offers only the integrated marketplaces', () => {
    expect(SHOW_MARKETPLACES).toBe(true);
    expect(MARKETPLACE_NETWORKS.map((n) => n.id)).toEqual(['stubhub', 'seatgeek', 'vivid', 'gametime', 'gotickets', 'evo']);
  });
});
