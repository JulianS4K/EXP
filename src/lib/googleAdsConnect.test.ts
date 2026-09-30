import { describe, expect, it } from 'vitest';
import { googleAdsErrorMessage, readGoogleAdsReturn, stripGoogleAdsReturn } from './googleAdsConnect';

const S = 'A'.repeat(43);

describe('Google Ads connect return', () => {
  it('reads finish / connected / error', () => {
    expect(readGoogleAdsReturn(`?google_ads=finish&google_ads_state=${S}`)).toEqual({ kind: 'finish', state: S });
    expect(readGoogleAdsReturn('?google_ads=finish&google_ads_state=short')).toEqual({ kind: 'error', reason: 'state' });
    expect(readGoogleAdsReturn('?google_ads=connected')).toEqual({ kind: 'connected' });
    expect(readGoogleAdsReturn('?google_ads=error&reason=denied')).toEqual({ kind: 'error', reason: 'denied' });
    expect(readGoogleAdsReturn('?google_ads=error&reason=<script>')).toEqual({ kind: 'error', reason: 'script' });
    expect(readGoogleAdsReturn('?tab=x')).toBeNull();
    expect(readGoogleAdsReturn('')).toBeNull();
  });

  it('strips only its own params', () => {
    expect(stripGoogleAdsReturn(`?tab=ads&google_ads=finish&google_ads_state=${S}`)).toBe('?tab=ads');
    expect(stripGoogleAdsReturn('?google_ads=error&reason=denied')).toBe('');
  });

  it('has a message for each reason', () => {
    expect(googleAdsErrorMessage('denied')).toMatch(/declined/);
    expect(googleAdsErrorMessage('whatever')).toMatch(/Try again/);
  });
});
