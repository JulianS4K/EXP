import { describe, expect, it } from 'vitest';
import {
  blankStore, coerceStoreDraft, parseLineup, parseMinAge, storeFromEvent, storeToInput, validateStore, videoEmbedUrl,
} from './storeContent';

describe('videoEmbedUrl', () => {
  it('maps YouTube and Vimeo links to the privacy-enhanced players', () => {
    expect(videoEmbedUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ')).toBe('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ');
    expect(videoEmbedUrl('https://youtu.be/dQw4w9WgXcQ?t=10')).toBe('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ');
    expect(videoEmbedUrl('https://m.youtube.com/shorts/dQw4w9WgXcQ')).toBe('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ');
    expect(videoEmbedUrl('https://vimeo.com/76979871')).toBe('https://player.vimeo.com/video/76979871?dnt=1');
  });
  it('refuses anything else', () => {
    for (const u of ['http://youtube.com/watch?v=dQw4w9WgXcQ', 'https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ',
      'https://www.youtube.com/watch?v=<script>', 'https://vimeo.com/channels', 'javascript:alert(1)', '', null]) {
      expect(videoEmbedUrl(u)).toBeNull();
    }
  });
});

describe('store draft', () => {
  it('round-trips an event into EventInput fields, deriving the plain description', () => {
    const d = storeFromEvent({
      description: 'old',
      summary: 'One line',
      descriptionMd: '**Big** night',
      lineup: [{ name: 'DJ Nova', role: 'headliner', setAt: '23:30' }, { name: '  ', role: 'dj' }],
      faq: [{ q: 'Parking?', a: 'Street.' }],
      gallery: [{ url: 'https://x.com/a.jpg' }],
      minAge: 21,
      refundPolicy: 'until_7d',
    });
    expect(validateStore(d)).toBeNull();
    expect(storeToInput(d)).toEqual({
      description: 'Big night',
      summary: 'One line',
      descriptionMd: '**Big** night',
      lineup: [{ name: 'DJ Nova', role: 'headliner', set_at: '23:30' }],
      faq: [{ q: 'Parking?', a: 'Street.' }],
      gallery: [{ url: 'https://x.com/a.jpg' }],
      videoUrl: null,
      minAge: 21,
      refundPolicy: 'until_7d',
      policyNotes: null,
    });
  });
  it('seeds the markdown from a legacy plain description', () => {
    expect(storeFromEvent({ description: 'Plain text' }).descriptionMd).toBe('Plain text');
  });
  it('clears explicitly', () => {
    expect(storeToInput(blankStore())).toMatchObject({ description: '', summary: null, descriptionMd: null, lineup: [], minAge: null });
  });
  it('catches what the database would reject', () => {
    const base = blankStore();
    expect(validateStore({ ...base, summary: 'x'.repeat(161) })).toMatch(/Summary/);
    expect(validateStore({ ...base, lineup: [{ name: 'A', role: 'dj', setAt: '9pm' }] })).toMatch(/Set time/);
    expect(validateStore({ ...base, faq: [{ q: 'Q', a: '' }] })).toMatch(/question and an answer/);
    expect(validateStore({ ...base, gallery: [{ url: 'http://x.com/a.jpg' }] })).toMatch(/https/);
    expect(validateStore({ ...base, videoUrl: 'https://evil.com/v' })).toMatch(/YouTube or Vimeo/);
  });
  it('reads rows and old drafts leniently', () => {
    expect(parseLineup([{ name: 'A', role: 'drummer', set_at: '21:00' }, { role: 'dj' }, 'x'])).toEqual([{ name: 'A', role: 'other', setAt: '21:00' }]);
    expect(parseMinAge(17)).toBeNull();
    expect(parseMinAge('21')).toBe(21);
    expect(coerceStoreDraft(undefined)).toEqual(blankStore());
    expect(coerceStoreDraft({ minAge: '18', refundPolicy: 'bogus' })).toMatchObject({ minAge: '18', refundPolicy: '' });
  });
});
