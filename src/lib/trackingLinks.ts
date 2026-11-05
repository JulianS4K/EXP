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
// The keys here are exactly what _exos_channel_key maps to itself, so a link
// made here lands on its own row in the report.

export interface TrackingChannel {
  key: string;
  label: string;
  /** utm_medium, GA4 convention (social / email / cpc / referral / offline). */
  medium: string;
}

export const TRACKING_CHANNELS: readonly TrackingChannel[] = [
  { key: 'instagram', label: 'Instagram', medium: 'social' },
  { key: 'facebook', label: 'Facebook', medium: 'social' },
  { key: 'tiktok', label: 'TikTok', medium: 'social' },
  { key: 'x', label: 'X / Twitter', medium: 'social' },
  { key: 'email', label: 'Email', medium: 'email' },
  { key: 'sms', label: 'Text message', medium: 'sms' },
  { key: 'whatsapp', label: 'WhatsApp', medium: 'messaging' },
  { key: 'partner', label: 'Partner sites', medium: 'referral' },
  { key: 'flyer', label: 'Flyer / QR code', medium: 'offline' },
  { key: 'meta-ads', label: 'Paid: Meta', medium: 'cpc' },
  { key: 'google-ads', label: 'Paid: Google', medium: 'cpc' },
];

const slug = (s: string) => s.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 64).replace(/-+$/, '');

/** The event URL tagged for one channel (any query the base already has is kept). */
export function trackingUrl(base: string, ch: TrackingChannel, campaign?: string): string {
  const u = new URL(base);
  u.searchParams.set('utm_source', ch.key);
  u.searchParams.set('utm_medium', ch.medium);
  const c = campaign ? slug(campaign) : '';
  if (c) u.searchParams.set('utm_campaign', c);
  else u.searchParams.delete('utm_campaign');
  return u.toString();
}

/** One link per channel. */
export function trackingLinks(base: string, campaign?: string): (TrackingChannel & { url: string })[] {
  return TRACKING_CHANNELS.map((ch) => ({ ...ch, url: trackingUrl(base, ch, campaign) }));
}
