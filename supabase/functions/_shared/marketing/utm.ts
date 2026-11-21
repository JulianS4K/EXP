// The one UTM scheme for links Exos builds for organizers (2026-11-21,
// docs/marketing-catalog.md "UTM scheme"):
//
//   utm_source    the platform or place: instagram, tiktok, meta, google, qr, email, ...
//   utm_medium    how it got there: paid_social, paid_search, print, email,
//                 organic_social (plus sms, messaging and referral for the
//                 channels that are none of those)
//   utm_campaign  the organizer's campaign name, else the ad platform's
//                 campaign macro on a paid link (filled in by the platform)
//   utm_content   the placement: a poster / flyer's slug on a print QR, the
//                 ad platform's ad macro on a paid link, the event id in a
//                 catalog
//
// The canonical event URL stays undecorated (the "Share the link" box, the
// <link rel=canonical>); only the per-channel copies carry tags. Google's
// gclid auto-tagging is left as it is: a click id is added by Google and read
// by the Sources report on its own. The channel report keys on source and
// medium (_exos_channel_key, mig 20261029120000; paid_search added in mig
// 20261121153700), so meta + paid_social is "Meta ads", google + paid_search
// "Google ads", qr + print "Flyer / QR code".
//
// Pure: no Deno, Node or Supabase imports (the SPA and the edge functions
// both load it).

export type UtmMedium =
  | 'paid_social' | 'paid_search' | 'print' | 'email' | 'organic_social'
  | 'sms' | 'messaging' | 'referral';

export const UTM_MEDIUMS: readonly UtmMedium[] = [
  'paid_social', 'paid_search', 'print', 'email', 'organic_social', 'sms', 'messaging', 'referral',
];

export type AdPlatform = 'meta' | 'tiktok' | 'google';

/** The paid medium of an ad platform: social feeds vs search / shopping. */
export function paidMedium(platform: AdPlatform): UtmMedium {
  return platform === 'google' ? 'paid_search' : 'paid_social';
}

// The platforms' own URL macros (filled in at click time). Meta: dynamic URL
// parameters ({{campaign.name}}, {{ad.name}}); TikTok: __CAMPAIGN_NAME__ and
// __CID_NAME__ (the ad); Google Ads: ValueTrack {campaignid} and {creative}.
export const AD_MACROS: Readonly<Record<AdPlatform, { campaign: string; content: string }>> = {
  meta: { campaign: '{{campaign.name}}', content: '{{ad.name}}' },
  tiktok: { campaign: '__CAMPAIGN_NAME__', content: '__CID_NAME__' },
  google: { campaign: '{campaignid}', content: '{creative}' },
};

export interface UtmTags {
  source: string;
  medium: UtmMedium;
  campaign?: string | null;
  content?: string | null;
}

const KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content'] as const;

// Braces stay literal: Meta and Google only fill in {{…}} / {…} as written.
const enc = (v: string) => encodeURIComponent(v).replace(/%7B/gi, '{').replace(/%7D/gi, '}');

/**
 * `base` with the tags set (replacing any utm_* it has; other parameters and
 * the fragment are kept). An empty campaign or content is left off.
 */
export function tagUrl(base: string, tags: UtmTags): string {
  const u = new URL(base);
  for (const k of KEYS) u.searchParams.delete(k);
  const rest = u.searchParams.toString();
  const pairs: Array<[string, string | null | undefined]> = [
    ['utm_source', tags.source], ['utm_medium', tags.medium],
    ['utm_campaign', tags.campaign], ['utm_content', tags.content],
  ];
  const ours = pairs.filter(([, v]) => v != null && String(v).trim() !== '')
    .map(([k, v]) => `${k}=${enc(String(v).trim())}`).join('&');
  const query = [rest, ours].filter(Boolean).join('&');
  return `${u.origin}${u.pathname}${query ? `?${query}` : ''}${u.hash}`;
}

/** A paid link for an ad platform: its medium and macros, or the organizer's campaign name. */
export function adTags(platform: AdPlatform, campaign?: string | null): UtmTags {
  const m = AD_MACROS[platform];
  return { source: platform, medium: paidMedium(platform), campaign: campaign || m.campaign, content: m.content };
}
