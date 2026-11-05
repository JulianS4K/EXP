import { describe, expect, it } from 'vitest';
import { isLinkCrawler } from './crawler';

describe('isLinkCrawler', () => {
  it('spots the unfurl bots', () => {
    expect(isLinkCrawler('facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)')).toBe(true);
    expect(isLinkCrawler('Twitterbot/1.0')).toBe(true);
    expect(isLinkCrawler('Mozilla/5.0 (compatible; Bytespider; spider-feedback@bytedance.com)')).toBe(true);
    expect(isLinkCrawler('Pinterest/0.2 (+http://www.pinterest.com/bot.html)')).toBe(true);
    expect(isLinkCrawler('WhatsApp/2.23.20.0')).toBe(true);
  });

  // A person in TikTok's or Pinterest's in-app browser carries the app's
  // name: they get the app, not a crawler's page (and no extra lookup).
  it('lets people in TikTok and Pinterest in-app browsers through', () => {
    const tiktok = 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 trill_350003 AppName/musical_ly TikTok/35.0.3 BytedanceWebview/d8a21c6';
    const pinterest = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [Pinterest/iOS]';
    expect(isLinkCrawler(tiktok)).toBe(false);
    expect(isLinkCrawler(pinterest)).toBe(false);
    expect(isLinkCrawler('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108')).toBe(false);
  });

  it('humans in real browsers are not crawlers', () => {
    expect(isLinkCrawler('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1')).toBe(false);
    expect(isLinkCrawler('')).toBe(false);
    expect(isLinkCrawler(null)).toBe(false);
  });
});
