// Tracking links: one link per channel (distribution spec §7 item 7).
//
// A tracking link is the event page with utm_source / utm_medium set, and no
// code. The storefront keeps the tags on the order (paid checkouts:
// exos_checkout_sessions.attribution; free claims: the ticket's channel), and
// the Channels report (mig 20261029120000, _exos_channel_key) credits the sale
// to the channel. Promo links (lib/promoLinks.ts) are for deals and limits:
// they carry a voucher code, and a code needs the buyer to sign in, so a plain
// tracking link stays code-free and works for guest checkout.
//
// Each link's source + medium is what _exos_channel_key maps to the channel's
// key, so a link made here lands on its own row in the report. The tags
// follow the one Exos scheme (_shared/marketing/utm.ts): organic_social,
// email, print, paid_social, paid_search, ...

import { adTags, tagUrl, type AdPlatform, type UtmMedium } from '../../supabase/functions/_shared/marketing/utm.ts';

export interface TrackingChannel {
  /** The channel report row this link lands on (_exos_channel_key of source + medium). */
  key: string;
  label: string;
  /** utm_source: the platform or place. */
  source: string;
  /** utm_medium, the Exos scheme (_shared/marketing/utm.ts). */
  medium: UtmMedium;
  /** Paid links: the ad platform whose macros fill campaign / content. */
  ad?: AdPlatform;
}

export const TRACKING_CHANNELS: readonly TrackingChannel[] = [
  { key: 'instagram', label: 'Instagram', source: 'instagram', medium: 'organic_social' },
  { key: 'facebook', label: 'Facebook', source: 'facebook', medium: 'organic_social' },
  { key: 'tiktok', label: 'TikTok', source: 'tiktok', medium: 'organic_social' },
  { key: 'x', label: 'X / Twitter', source: 'x', medium: 'organic_social' },
  { key: 'email', label: 'Email', source: 'email', medium: 'email' },
  { key: 'sms', label: 'Text message', source: 'sms', medium: 'sms' },
  { key: 'whatsapp', label: 'WhatsApp', source: 'whatsapp', medium: 'messaging' },
  { key: 'partner', label: 'Partner sites', source: 'partner', medium: 'referral' },
  // Partiful: the organizer's invite page sends guests to Exos (referral; no API, nothing read).
  { key: 'partiful', label: 'Partiful', source: 'partiful', medium: 'referral' },
  { key: 'flyer', label: 'Flyer / QR code', source: 'qr', medium: 'print' },
  { key: 'meta-ads', label: 'Paid: Meta', source: 'meta', medium: 'paid_social', ad: 'meta' },
  { key: 'google-ads', label: 'Paid: Google', source: 'google', medium: 'paid_search', ad: 'google' },
];

const slug = (s: string) => s.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 64).replace(/-+$/, '');

/**
 * The event URL tagged for one channel (any query the base already has is
 * kept). Paid links carry the ad platform's macros: its ad in utm_content,
 * and its campaign unless the organizer named one.
 */
export function trackingUrl(base: string, ch: TrackingChannel, campaign?: string): string {
  const c = campaign ? slug(campaign) : '';
  const tags = ch.ad ? adTags(ch.ad, c || null) : { source: ch.source, medium: ch.medium, campaign: c || null };
  return tagUrl(base, tags);
}

/** One link per channel. */
export function trackingLinks(base: string, campaign?: string): (TrackingChannel & { url: string })[] {
  return TRACKING_CHANNELS.map((ch) => ({ ...ch, url: trackingUrl(base, ch, campaign) }));
}
