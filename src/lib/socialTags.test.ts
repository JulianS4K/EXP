import { describe, expect, it } from 'vitest';
import { cleanHandle, mentionsFor, orgTagSource, withMentions } from './socialTags';

describe('cleanHandle', () => {
  it('accepts @name, bare names and profile URLs', () => {
    expect(cleanHandle('@dj.kay', 'instagram')).toBe('dj.kay');
    expect(cleanHandle('https://www.instagram.com/dj.kay/?hl=en', 'instagram')).toBe('dj.kay');
    expect(cleanHandle('tiktok.com/@djkay', 'tiktok')).toBe('djkay');
    expect(cleanHandle('https://twitter.com/djkay', 'x')).toBe('djkay');
  });
  it('rejects what the platform would not allow', () => {
    expect(cleanHandle('dj kay', 'instagram')).toBeNull();
    expect(cleanHandle('dj.kay', 'x')).toBeNull(); // X has no dots
    expect(cleanHandle('', 'instagram')).toBeNull();
    expect(cleanHandle(undefined, 'tiktok')).toBeNull();
  });
});

describe('mentionsFor', () => {
  const org = orgTagSource({ marketing: { socials: { instagram: 'https://instagram.com/bknights', x: '@bknights' } } })!;
  const promoter = { handles: { instagram: 'dj.kay', x: 'djkay' } };

  it('uses each platform\'s own handle', () => {
    expect(mentionsFor('x', [org, promoter])).toEqual(['@bknights', '@djkay']);
    expect(mentionsFor('whatsapp', [org, promoter])).toEqual(['@bknights', '@dj.kay']);
    expect(mentionsFor('instagram_story', [org, promoter])).toEqual(['@bknights', '@dj.kay']);
  });
  it('adds nothing where the platform drops pre-filled text', () => {
    expect(mentionsFor('facebook', [org, promoter])).toEqual([]);
  });
  it('respects each account\'s switch', () => {
    const off = orgTagSource({ marketing: { socials: { instagram: 'bknights' }, allowTagging: false } })!;
    expect(mentionsFor('native', [off, promoter])).toEqual(['@dj.kay']);
    expect(mentionsFor('native', [org, { handles: promoter.handles, allowed: false }])).toEqual(['@bknights']);
  });
  it('skips missing or invalid handles and de-duplicates', () => {
    expect(mentionsFor('x', [{ handles: { instagram: 'only.ig' } }])).toEqual([]);
    expect(mentionsFor('native', [{ handles: { instagram: 'Same' } }, { handles: { instagram: 'same' } }])).toEqual(['@Same']);
    expect(mentionsFor('native', [{ handles: { instagram: 'bad handle!' } }])).toEqual([]);
    expect(orgTagSource(null)).toBeNull();
  });
});

describe('withMentions', () => {
  it('appends mentions only when there are some', () => {
    expect(withMentions("I'm going!", ['@a', '@b'])).toBe("I'm going! with @a @b");
    expect(withMentions("I'm going!", [])).toBe("I'm going!");
  });
});
