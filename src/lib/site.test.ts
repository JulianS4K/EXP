import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import { cleanSite, parseSite, siteError, splitAroundEvents, starterSite } from './site';
import { buttonColor, groupByMonth, upcomingForEmbed, widgetSnippets } from './embedWidgets';
import { Timestamp } from './timestamp';

describe('site sections', () => {
  it('checks the shape like the database', () => {
    expect(siteError(starterSite('Hall'))).toBeNull();
    expect(siteError({ sections: [{ type: 'script' as never }] })).toMatch(/unknown/);
    expect(siteError({ sections: [{ type: 'hero', image: 'javascript:x' }] })).toMatch(/https/);
    expect(siteError({ sections: [{ type: 'links', items: [{ label: 'x', url: 'http://x' }] }] })).toMatch(/https/);
    expect(siteError({ sections: Array.from({ length: 21 }, () => ({ type: 'text' as const })) })).toMatch(/20/);
  });
  it('cleans empties and splits around the events grid', () => {
    const s = cleanSite({ sections: [{ type: 'hero', title: ' Hall ', subtitle: '' }, { type: 'about', body: 'Hi' }, { type: 'events' },
      { type: 'faq', items: [{ q: 'Age?', a: '21+' }, { q: '', a: '' }] }] });
    expect(s.sections[0]).toEqual({ type: 'hero', title: 'Hall' });
    expect(s.sections[3].items).toHaveLength(1);
    const p = splitAroundEvents(s);
    expect(p.hero?.title).toBe('Hall');
    expect(p.before.map((x) => x.type)).toEqual(['about']);
    expect(p.after.map((x) => x.type)).toEqual(['faq']);
    expect(splitAroundEvents({ sections: [{ type: 'text' }] }).after).toHaveLength(1);
    expect(parseSite({ sections: [{ type: 'nope' }] })).toBeNull();
  });
});

describe('widgets', () => {
  const ev = (id: string, ms: number, tz = 'America/New_York') => ({ id, date: Timestamp.fromMillis(ms), timezone: tz }) as any;
  it('upcoming, soonest first; grouped by month', () => {
    const now = Date.UTC(2026, 9, 16);
    const list = upcomingForEmbed([ev('b', now + 40 * 86400_000), ev('old', now - 86400_000), ev('a', now + 86400_000)], now);
    expect(list.map((e) => e.id)).toEqual(['a', 'b']);
    expect(groupByMonth(list).map((g) => g.label)).toEqual(['October 2026', 'November 2026']);
  });
  it('snippets and colours', () => {
    const s = widgetSnippets('https://x.com/bridge/embed.js', 'wl-hall', 'e1');
    expect(s.map((x) => x.label)).toEqual(['Event list', 'Calendar', 'Buy button', 'Ticket box (checkout on your page)']);
    expect(s[0].html).toContain('data-exos-org="wl-hall"');
    expect(buttonColor('#ff3366')).toBe('#ff3366');
    expect(buttonColor('red;x')).toBeNull();
  });
});
