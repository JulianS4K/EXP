// Attributed share links for the two people who share an event:
//   * a FAN ("I'm going"): tagged utm_medium=fan_share, and a promoter code
//     the fan arrived with is passed along, so the promoter who brought them
//     is still credited for the friends they bring;
//   * a PROMOTER: every link carries their promoter code (which the Sales
//     report groups by) plus the channel, so they can see what works.
// The same links feed the web share sheet today and the native app's
// Instagram / Facebook Stories hand-off later (lib/nativeShare.ts).

import { withAttribution, type Attribution } from './attribution';
import { sanitizePromoter, sanitizeTag } from '../../supabase/functions/_shared/attribution.ts';

export type ShareRole = 'fan' | 'promoter';

export type ShareChannel =
  | 'instagram_story' | 'instagram_feed' | 'instagram_bio'
  | 'facebook_story' | 'facebook'
  | 'tiktok' | 'x' | 'whatsapp' | 'sms' | 'email' | 'copy' | 'native';

const SOURCE: Record<ShareChannel, string> = {
  instagram_story: 'instagram', instagram_feed: 'instagram', instagram_bio: 'instagram',
  facebook_story: 'facebook', facebook: 'facebook',
  tiktok: 'tiktok', x: 'x', whatsapp: 'whatsapp', sms: 'sms', email: 'email',
  copy: 'link', native: 'share_sheet',
};

const PROMOTER_MEDIUM: Partial<Record<ShareChannel, string>> = {
  instagram_story: 'story', facebook_story: 'story', instagram_feed: 'social', instagram_bio: 'bio',
  facebook: 'social', tiktok: 'social', x: 'social', whatsapp: 'messaging', sms: 'messaging', email: 'email',
};

export interface ShareOptions {
  role: ShareRole;
  channel: ShareChannel;
  /** Promoter: their own code. Fan: the code they arrived with, if any. */
  promoter?: string;
  /** Promoter campaign name (defaults to the promoter code). */
  campaign?: string;
}

export function shareAttribution(opts: ShareOptions): Attribution {
  const promoter = sanitizePromoter(opts.promoter);
  const out: Attribution = { utm_source: SOURCE[opts.channel] };
  if (opts.role === 'fan') {
    out.utm_medium = 'fan_share';
    if (promoter) out.promoter = promoter;
    return out;
  }
  out.utm_medium = PROMOTER_MEDIUM[opts.channel] ?? 'referral';
  if (promoter) {
    out.promoter = promoter;
    out.utm_campaign = sanitizeTag(opts.campaign) ?? promoter;
  }
  return out;
}

// A promoter code from a display name. Same rule as _shared/attribution.ts
// sanitizePromoter: 1-64 of [A-Za-z0-9_-].
export function codeFromName(name: string): string {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 64).replace(/-+$/, '');
}

export function buildShareUrl(eventUrl: string, opts: ShareOptions): string {
  return withAttribution(eventUrl, shareAttribution(opts));
}
