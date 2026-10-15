import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import { cleanCode, codeFromSearch, dealText, parsePromoLink, promoUrl, redemptionText, slugChannel } from './promoLinks';

describe('promo links', () => {
  it('builds the shareable URL with the code and UTM', () => {
    const u = new URL(promoUrl('e1', { code: 'IGSTORY', channel: 'instagram', label: 'Story, Oct 20' }, 'https://x.com/bridge/event/e1'));
    expect(u.searchParams.get('code')).toBe('IGSTORY');
    expect(u.searchParams.get('utm_source')).toBe('instagram');
    expect(u.searchParams.get('utm_medium')).toBe('promo_link');
    expect(u.searchParams.get('utm_campaign')).toBe('story-oct-20');
    expect(new URL(promoUrl('e1', { code: 'A1', channel: null, label: '' }, 'https://x.com/e')).searchParams.get('utm_source')).toBe('promo');
  });
  it('reads a code from the page URL', () => {
    expect(codeFromSearch('?code=IGSTORY&utm_source=x')).toBe('IGSTORY');
    expect(codeFromSearch('code=a')).toBeNull();
    expect(codeFromSearch('?code=<b>')).toBeNull();
    expect(codeFromSearch('')).toBeNull();
  });
  it('cleans codes and channels', () => {
    expect(cleanCode(' ig-story 20! ')).toBe('IGSTORY20');
    expect(slugChannel(' Instagram Story ')).toBe('instagram-story');
  });
  it('says how many are left and what the deal is', () => {
    expect(redemptionText({ used: 3, maxUses: 10 })).toBe('3 of 10 used · 7 left');
    expect(redemptionText({ used: 10, maxUses: 10 })).toBe('All 10 used');
    expect(dealText({ discountPercent: 20, discountAmount: null })).toBe('20% off');
    expect(dealText({ discountPercent: null, discountAmount: 5 })).toBe('$5.00 off');
    expect(dealText({ discountPercent: null, discountAmount: null })).toMatch(/tracking/);
    expect(parsePromoLink({ voucher_id: 'v', code: 'A', label: 'L', clicks: '4', used: 1, max_uses: 5 })).toMatchObject({ clicks: 4, maxUses: 5 });
  });
});
