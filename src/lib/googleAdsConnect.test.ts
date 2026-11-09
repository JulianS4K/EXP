import { describe, expect, it } from 'vitest';
import { googleAdsErrorMessage } from './googleAdsConnect';

describe('Google Ads connect messages', () => {
  it('has a message for each reason', () => {
    expect(googleAdsErrorMessage('denied')).toMatch(/declined/);
    expect(googleAdsErrorMessage('whatever')).toMatch(/Try again/);
  });
});
