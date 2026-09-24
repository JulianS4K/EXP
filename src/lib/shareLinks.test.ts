import { describe, expect, it } from 'vitest';
import { buildShareUrl, shareAttribution } from './shareLinks';
import { getNativeBridge, validateNativePayload } from './nativeShare';

const EVENT = 'https://exos.example/bridge/event/1';

describe('shareAttribution', () => {
  it('tags a fan share and passes along the promoter they came from', () => {
    expect(shareAttribution({ role: 'fan', channel: 'instagram_story', promoter: 'dj-kay' }))
      .toEqual({ utm_source: 'instagram', utm_medium: 'fan_share', promoter: 'dj-kay' });
  });
  it('tags a fan share with no promoter', () => {
    expect(shareAttribution({ role: 'fan', channel: 'sms' })).toEqual({ utm_source: 'sms', utm_medium: 'fan_share' });
  });
  it('credits the promoter on every channel, campaign defaulting to their code', () => {
    expect(shareAttribution({ role: 'promoter', channel: 'instagram_story', promoter: 'dj-kay' }))
      .toEqual({ utm_source: 'instagram', utm_medium: 'story', promoter: 'dj-kay', utm_campaign: 'dj-kay' });
    expect(shareAttribution({ role: 'promoter', channel: 'instagram_bio', promoter: 'dj-kay', campaign: 'fall launch' }))
      .toEqual({ utm_source: 'instagram', utm_medium: 'bio', promoter: 'dj-kay', utm_campaign: 'fall launch' });
  });
  it('drops an unsafe promoter code', () => {
    expect(shareAttribution({ role: 'promoter', channel: 'x', promoter: '<b>' })).toEqual({ utm_source: 'x', utm_medium: 'social' });
  });
  it('builds the URL', () => {
    expect(buildShareUrl(EVENT, { role: 'fan', channel: 'whatsapp' }))
      .toBe(`${EVENT}?utm_source=whatsapp&utm_medium=fan_share`);
  });
});

describe('getNativeBridge', () => {
  const ok = { version: 1, canShare: async () => true, share: async () => 'shared' as const };
  it('accepts a v1 bridge', () => expect(getNativeBridge({ ExosNative: ok })).toBe(ok));
  it('ignores missing, old or malformed bridges', () => {
    expect(getNativeBridge({})).toBeNull();
    expect(getNativeBridge({ ExosNative: { ...ok, version: 2 } })).toBeNull();
    expect(getNativeBridge({ ExosNative: { version: 1 } })).toBeNull();
  });
});

describe('validateNativePayload', () => {
  const png = 'data:image/png;base64,iVBORw0KGgo=';
  it('accepts a story with a background image', () => {
    expect(validateNativePayload({ target: 'instagram_story', backgroundImage: png, contentUrl: EVENT })).toEqual([]);
  });
  it('accepts a sticker over a gradient', () => {
    expect(validateNativePayload({ target: 'facebook_story', stickerImage: png, backgroundTopColor: '#000000', backgroundBottomColor: '#FF00FF', contentUrl: EVENT })).toEqual([]);
  });
  it('rejects bad images, colors, empty stories and non-https links', () => {
    const p = validateNativePayload({ target: 'instagram_story', backgroundImage: 'https://x/y.png', backgroundTopColor: 'red', contentUrl: 'http://x' });
    expect(p).toEqual(expect.arrayContaining([
      'backgroundImage must be a PNG or JPEG data URL', 'backgroundTopColor must be #RRGGBB', 'contentUrl must be https',
    ]));
    expect(validateNativePayload({ target: 'instagram_story', contentUrl: EVENT })).toContain('a story needs a background or a sticker');
    expect(validateNativePayload({ target: 'instagram_feed', contentUrl: EVENT })).toContain('instagram_feed needs backgroundImage');
  });
});

import { codeFromName } from './shareLinks';
import { sanitizePromoter } from '../../supabase/functions/_shared/attribution.ts';

describe('codeFromName', () => {
  it('makes a valid promoter code', () => {
    expect(codeFromName('DJ Kay!')).toBe('dj-kay');
    expect(codeFromName('  Mo  B  ')).toBe('mo-b');
    const long = codeFromName('a'.repeat(40) + ' ' + 'b'.repeat(40));
    expect(long.length).toBeLessThanOrEqual(64);
    expect(sanitizePromoter(long)).toBe(long);
    expect(codeFromName('!!!')).toBe('');
  });
});
