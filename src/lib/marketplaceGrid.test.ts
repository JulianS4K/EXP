import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { sameOnAll } from '../components/ChannelLinks';
import { MARKETPLACE_NETWORKS, SHOW_MARKETPLACES } from './tierType';
import { parseMarketplacePrice } from './marketplace/stubhubStatus';

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

describe('marketplace price per cell', () => {
  it('blank or the Exos price follows the ticket type', () => {
    expect(parseMarketplacePrice('', 45)).toEqual({ ok: true, price: null });
    expect(parseMarketplacePrice('  ', 45)).toEqual({ ok: true, price: null });
    expect(parseMarketplacePrice('45', 45)).toEqual({ ok: true, price: null });
  });

  it('takes a higher price, with or without a dollar sign', () => {
    expect(parseMarketplacePrice('52.50', 45)).toEqual({ ok: true, price: 52.5 });
    expect(parseMarketplacePrice('$60', 45)).toEqual({ ok: true, price: 60 });
  });

  it('never below the Exos price, never malformed', () => {
    expect(parseMarketplacePrice('44.99', 45)).toMatchObject({ ok: false, error: expect.stringMatching(/never undercut/) });
    expect(parseMarketplacePrice('0', 0)).toMatchObject({ ok: false });
    expect(parseMarketplacePrice('4.999', 1)).toMatchObject({ ok: false });
    expect(parseMarketplacePrice('abc', 1)).toMatchObject({ ok: false });
    expect(parseMarketplacePrice('-5', 1)).toMatchObject({ ok: false });
  });
});
