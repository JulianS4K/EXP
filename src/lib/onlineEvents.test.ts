import { describe, expect, it } from 'vitest';
import {
  blankOnline, coerceOnlineDraft, formatLabel, isJoinUrl, joinLinkFor, needsVenue, onlineFromEvent, onlineToInput, parseEventFormat,
  validateOnline, WHAT_TO_BRING_MAX,
} from './onlineEvents';

describe('onlineEvents', () => {
  it('parses the format, defaulting to in person', () => {
    expect(parseEventFormat('online')).toBe('online');
    expect(parseEventFormat('hybrid')).toBe('hybrid');
    expect(parseEventFormat('virtual')).toBe('in_person');
    expect(parseEventFormat(null)).toBe('in_person');
    expect(formatLabel('in_person')).toBeNull();
    expect(formatLabel('online')).toBe('Online');
  });

  it('accepts only https join links', () => {
    expect(isJoinUrl(' https://zoom.us/j/123?pwd=x ')).toBe(true);
    for (const u of ['http://zoom.us/j/1', 'javascript:alert(1)', 'https://x.com/a"onerror', '', 'zoom.us/j/1']) {
      expect(isJoinUrl(u)).toBe(false);
    }
  });

  it('validates the draft', () => {
    const d = blankOnline();
    expect(validateOnline(d)).toBeNull();
    expect(validateOnline({ ...d, whatToBring: 'x'.repeat(WHAT_TO_BRING_MAX + 1) })).toMatch(/What to bring/);
    expect(validateOnline({ ...d, format: 'online', joinUrl: 'http://x.com' })).toMatch(/https/);
    // An in-person event ignores a leftover link; an empty link is fine (set later).
    expect(validateOnline({ ...d, format: 'in_person', joinUrl: 'http://x.com' })).toBeNull();
    expect(validateOnline({ ...d, format: 'online', joinUrl: '' })).toBeNull();
  });

  it('builds the event columns and the join link', () => {
    const d = { ...blankOnline(), format: 'hybrid' as const, whatToBring: '  ID  ', joinUrl: ' https://s.tv/x ',
      joinNote: ' pw 1 ', reveal: '60' };
    expect(onlineToInput(d)).toEqual({ format: 'hybrid', whatToBring: 'ID', noindex: false });
    expect(joinLinkFor(d)).toEqual({ url: 'https://s.tv/x', note: 'pw 1', revealMinutes: 60 });
    expect(joinLinkFor({ ...d, reveal: '' })!.revealMinutes).toBeNull();
    // In person: leave the saved link alone (switching back restores it).
    expect(joinLinkFor({ ...d, format: 'in_person' })).toBeNull();
    expect(onlineToInput({ ...d, whatToBring: '   ' }).whatToBring).toBeNull();
  });

  it('round-trips from an event and its link', () => {
    const d = onlineFromEvent({ format: 'online', whatToBring: 'Headphones', noindex: true },
      { joinUrl: 'https://s.tv/x', joinNote: null, revealMinutes: 0 });
    expect(d).toEqual({ format: 'online', whatToBring: 'Headphones', noindex: true, joinUrl: 'https://s.tv/x',
      joinNote: '', reveal: '0' });
    expect(onlineFromEvent({}).format).toBe('in_person');
  });

  it('only fully online events drop the venue', () => {
    expect(needsVenue('online')).toBe(false);
    expect(needsVenue('hybrid')).toBe(true);
    expect(needsVenue('in_person')).toBe(true);
  });

  it('coerces a stored draft', () => {
    expect(coerceOnlineDraft(undefined)).toEqual(blankOnline());
    expect(coerceOnlineDraft({ format: 'online', reveal: '45', noindex: 'yes', joinUrl: 7 }))
      .toEqual({ ...blankOnline(), format: 'online' });
    expect(coerceOnlineDraft({ reveal: '60' }).reveal).toBe('60');
  });
});
