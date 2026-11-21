import { describe, expect, it } from 'vitest';
import { AD_MACROS, UTM_MEDIUMS, adTags, paidMedium, tagUrl } from '../../../supabase/functions/_shared/marketing/utm.ts';
import { readAttribution } from '../../../supabase/functions/_shared/attribution.ts';

describe('UTM scheme', () => {
  it('has the five media plus the three non-paid extras', () => {
    expect(UTM_MEDIUMS.slice(0, 5)).toEqual(['paid_social', 'paid_search', 'print', 'email', 'organic_social']);
    expect(paidMedium('meta')).toBe('paid_social');
    expect(paidMedium('tiktok')).toBe('paid_social');
    expect(paidMedium('google')).toBe('paid_search');
  });

  it('sets the tags, replaces old ones and keeps other parameters and the fragment', () => {
    expect(tagUrl('https://exos.example/e/x', { source: 'qr', medium: 'print', content: 'poster-bedford-ave' }))
      .toBe('https://exos.example/e/x?utm_source=qr&utm_medium=print&utm_content=poster-bedford-ave');
    expect(tagUrl('https://exos.example/e/x?ref=abc&utm_source=old&utm_campaign=old#tix', { source: 'email', medium: 'email', campaign: 'launch' }))
      .toBe('https://exos.example/e/x?ref=abc&utm_source=email&utm_medium=email&utm_campaign=launch#tix');
    expect(tagUrl('https://exos.example/e/x', { source: 'instagram', medium: 'organic_social', campaign: ' ', content: null }))
      .toBe('https://exos.example/e/x?utm_source=instagram&utm_medium=organic_social');
    // Values are encoded; only braces stay literal.
    expect(tagUrl('https://exos.example/e/x', { source: 'partner', medium: 'referral', content: 'a b&c' }))
      .toBe('https://exos.example/e/x?utm_source=partner&utm_medium=referral&utm_content=a%20b%26c');
  });

  it('puts the platform macros in paid links, the organizer campaign first', () => {
    expect(adTags('meta')).toEqual({ source: 'meta', medium: 'paid_social', campaign: '{{campaign.name}}', content: '{{ad.name}}' });
    expect(adTags('tiktok', 'fall')).toEqual({ source: 'tiktok', medium: 'paid_social', campaign: 'fall', content: '__CID_NAME__' });
    expect(tagUrl('https://exos.example/e/x', adTags('google')))
      .toBe('https://exos.example/e/x?utm_source=google&utm_medium=paid_search&utm_campaign={campaignid}&utm_content={creative}');
    expect(Object.keys(AD_MACROS)).toEqual(['meta', 'tiktok', 'google']);
  });

  it('builds tags the attribution sanitizer keeps', () => {
    const u = new URL(tagUrl('https://exos.example/e/x', { source: 'qr', medium: 'print', content: 'flyer-bar-x' }));
    expect(readAttribution((k) => u.searchParams.get(k) ?? undefined))
      .toEqual({ utm_source: 'qr', utm_medium: 'print', utm_content: 'flyer-bar-x' });
  });
});
