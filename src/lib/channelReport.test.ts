// Sales by channel reader (supabase/functions/_shared/channelReport.ts, mig 20261029120000).
import { describe, it, expect } from 'vitest';
import {
  feeText, money, notReportedNote, parseChannel, parseChannelReport, parseEventChannels, parseFigures, sideCounts,
  sumTickets, totalsText, weekLabel,
} from '../../supabase/functions/_shared/channelReport.ts';
import { trackingLinks, trackingUrl, TRACKING_CHANNELS } from './trackingLinks';

const EV = '11111111-1111-4111-8111-111111111111';

describe('parse', () => {
  it('keeps not-reported figures as null, never zero', () => {
    expect(parseFigures([4, null, null, 0, null])).toEqual({ tickets: 4, grossCents: null, feeCents: null, exosFeeCents: 0, netCents: null });
    expect(parseFigures(['2', '500', 10, 0, 490])).toEqual({ tickets: 2, grossCents: 500, feeCents: 10, exosFeeCents: 0, netCents: 490 });
    expect(parseFigures(null)).toBeNull();
  });

  it('a channel without dates has no week', () => {
    const r = parseChannel({ channel: 'luma', label: 'Luma', kind: 'sale', dated: false, week: [1, 0, 0, 0, 0], to_date: [5, null, null, 0, null], fees: 'not_reported' });
    expect(r?.week).toBeNull();
    expect(r?.toDate.tickets).toBe(5);
    expect(parseChannel({ channel: '', to_date: [1] })).toBeNull();
    expect(parseChannel({ channel: 'x', to_date: [1], kind: 'weird', fees: 'weird' })).toMatchObject({ kind: 'sale', fees: 'not_reported' });
  });

  it('splits an event into sales, comps and imported attendees', () => {
    const e = parseEventChannels({
      id: EV, name: 'Show', currency: 'USD', channels: [
        { channel: 'instagram', kind: 'sale', dated: true, week: [1, 100, 0, 0, 100], to_date: [2, 200, 0, 0, 200] },
        { channel: 'comp', kind: 'comp', dated: true, week: [3, null, 0, 0, null], to_date: [4, null, 0, 0, null] },
        { channel: 'import:posh', kind: 'attendee', dated: true, week: [0, null, null, null, null], to_date: [1, null, null, null, null] },
      ],
    })!;
    expect(e.currency).toBe('usd');
    expect(e.sales.map((r) => r.channel)).toEqual(['instagram']);
    expect(sideCounts(e, 'week')).toEqual({ comps: 3, attendees: 0 });
    expect(sideCounts(e, 'toDate')).toEqual({ comps: 4, attendees: 1 });
    expect(parseEventChannels({ name: 'no id' })).toBeNull();
  });

  it('reads the weekly document', () => {
    const r = parseChannelReport({ org: { id: 'o', name: 'Org' }, from: '2026-10-19T00:00:00Z', to: '2026-10-26T00:00:00Z', events: [{ id: EV, channels: [] }, 'bad'], more_events: 1 })!;
    expect(r.orgName).toBe('Org');
    expect(r.events).toHaveLength(1);
    expect(r.moreEvents).toBe(1);
    expect(r.totals).toEqual({ week: [], toDate: [] });
    expect(parseChannelReport('x')).toBeNull();
  });
});

describe('format', () => {
  it('money says "not reported" for a missing figure', () => {
    expect(money(123456, 'usd')).toBe('$1,234.56');
    expect(money(null, 'usd')).toBe('not reported');
    expect(money(100, 'zzz1')).toBe('1.00 ZZZ1');
  });

  it('fee cell: none / amount / not reported', () => {
    expect(feeText({ tickets: 1, grossCents: 0, feeCents: 0, exosFeeCents: 0, netCents: 0 }, 'none', 'usd')).toBe('none');
    expect(feeText({ tickets: 1, grossCents: 500, feeCents: 25, exosFeeCents: 15, netCents: 460 }, 'reported', 'usd')).toBe('$0.25');
    expect(feeText({ tickets: 1, grossCents: null, feeCents: null, exosFeeCents: 0, netCents: null }, 'not_reported', 'usd')).toBe('not reported');
  });

  it('totals leave out money a channel did not report, and say so', () => {
    const t = [{ currency: 'usd', tickets: 10, grossCents: 5000, feeCents: 100, exosFeeCents: 150, netCents: 4750, grossNotReported: 4, netNotReported: 4 }];
    expect(totalsText(t)).toBe('10 tickets, $50.00 gross, $47.50 net');
    expect(totalsText([{ ...t[0], tickets: 4 }])).toBe('4 tickets');
    expect(totalsText([])).toBe('no tickets');
    expect(sumTickets(t)).toBe(10);
    expect(notReportedNote(t)).toBe("4 tickets came through channels that don't report prices or fees to Exos, so they aren't in the money totals.");
    expect(notReportedNote([{ ...t[0], grossNotReported: 0, netNotReported: 1 }])).toBe("1 ticket came through channels that don't report fees to Exos, so it isn't in the money totals.");
    expect(notReportedNote([{ ...t[0], grossNotReported: 0, netNotReported: 0 }])).toBe('');
  });

  it('week label is Monday to Sunday (UTC)', () => {
    expect(weekLabel('2026-10-19T00:00:00Z', '2026-10-26T00:00:00Z')).toBe('Oct 19 – Oct 25');
    expect(weekLabel(null, null)).toBe('');
  });
});

describe('tracking links', () => {
  it('one code-free link per channel, tagged so the sale is credited to it', () => {
    const links = trackingLinks('https://exos.example/bridge/event/abc');
    expect(links.map((l) => l.key)).toEqual(TRACKING_CHANNELS.map((c) => c.key));
    expect(new Set(links.map((l) => l.url)).size).toBe(links.length);
    const ig = new URL(trackingUrl('https://exos.example/bridge/event/abc', TRACKING_CHANNELS.find((c) => c.key === 'instagram')!));
    expect(ig.searchParams.get('utm_source')).toBe('instagram');
    expect(ig.searchParams.get('utm_medium')).toBe('social');
    expect(ig.searchParams.get('code')).toBeNull();
    const ads = new URL(trackingUrl('https://exos.example/e/x?ref=abc', TRACKING_CHANNELS.find((c) => c.key === 'meta-ads')!, 'Fall Push!'));
    expect(ads.searchParams.get('utm_campaign')).toBe('fall-push');
    expect(ads.searchParams.get('ref')).toBe('abc');
  });
});
