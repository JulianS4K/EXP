import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { isHexColor, mergeOrgTheme } from './orgs';

describe('org theme helpers', () => {
  it('isHexColor takes #rgb / #rrggbb only', () => {
    expect(isHexColor('#FFE714')).toBe(true);
    expect(isHexColor('#abc')).toBe(true);
    expect(isHexColor('FFE714')).toBe(false);
    expect(isHexColor('#FFE71')).toBe(false);
    expect(isHexColor('red')).toBe(false);
    expect(isHexColor('')).toBe(false);
  });

  it('mergeOrgTheme keeps the logo (and other keys) the patch leaves out', () => {
    const prev = { logoUrl: 'https://cdn/logo.png', primaryColor: '#000', customDomain: 'tix.club.com' };
    expect(mergeOrgTheme(prev, { primaryColor: '#FFE714', accentColor: '#0A0A0A' })).toEqual({
      logoUrl: 'https://cdn/logo.png', primaryColor: '#FFE714', accentColor: '#0A0A0A', customDomain: 'tix.club.com',
    });
    expect(mergeOrgTheme(undefined, { logoUrl: 'u', primaryColor: undefined })).toEqual({ logoUrl: 'u' });
  });
});
