// Auto-tagging on shares: when a fan or promoter shares an event, the text
// names the organizer and the promoter (@handles) wherever the platform lets
// a website pre-fill text, and only if that account allows being tagged
// (operator decision 2026-09-25).
//
//   * X, WhatsApp, SMS, email, the share sheet: the text carries the @handles.
//   * Facebook's sharer drops pre-filled text, so nothing is added there.
//   * Instagram Stories can't be pre-filled from the web: the handles are
//     printed on the story poster instead (lib/poster.ts), for the sharer to
//     turn into mention stickers.
// Handles come from the org's marketing.socials (switch: marketing.allowTagging,
// default on) and the promoter's public card (exos_public_promoter returns
// handles only while the promoter's allow_tagging is on; mig 20260925010000).

import type { ShareChannel } from './shareLinks';

export type SocialPlatform = 'instagram' | 'tiktok' | 'x';
export type SocialHandles = Partial<Record<SocialPlatform, string>>;

export interface TagSource {
  handles?: SocialHandles | Record<string, string | undefined> | null;
  /** The account's own switch. Defaults to allowed. */
  allowed?: boolean;
}

const HANDLE_RE: Record<SocialPlatform, RegExp> = {
  instagram: /^[A-Za-z0-9._]{1,30}$/,
  tiktok: /^[A-Za-z0-9._]{1,24}$/,
  x: /^[A-Za-z0-9_]{1,15}$/,
};

const HOSTS: Record<SocialPlatform, RegExp> = {
  instagram: /^(https?:\/\/)?(www\.)?instagram\.com\//i,
  tiktok: /^(https?:\/\/)?(www\.)?tiktok\.com\/@?/i,
  x: /^(https?:\/\/)?(www\.)?(x|twitter)\.com\//i,
};

/** "@name", "name" or a profile URL → "name"; null if it isn't a valid handle.
 *  Same rules as exos_clean_socials + exos_socials_valid in the database. */
export function cleanHandle(raw: string | null | undefined, platform: SocialPlatform): string | null {
  if (!raw) return null;
  const bare = raw.trim().replace(HOSTS[platform], '').replace(/^@/, '').replace(/[/?#].*$/, '');
  return HANDLE_RE[platform].test(bare) ? bare : null;
}

/** Which account's handle a channel's text should use. */
function platformFor(channel: ShareChannel): SocialPlatform | null {
  switch (channel) {
    case 'x':
      return 'x';
    case 'tiktok':
      return 'tiktok';
    case 'facebook':
    case 'facebook_story':
      return null; // Facebook's sharer ignores pre-filled text
    default:
      // Messaging, email, copy, the share sheet and Instagram: Instagram is
      // where these scenes live (docs/gtm-nyc.md), so name that account.
      return 'instagram';
  }
}

/** The @mentions for a share on this channel, de-duplicated, at most three. */
export function mentionsFor(channel: ShareChannel, sources: TagSource[]): string[] {
  const platform = platformFor(channel);
  if (!platform) return [];
  const out: string[] = [];
  for (const s of sources) {
    if (!s || s.allowed === false || !s.handles) continue;
    const h = cleanHandle((s.handles as Record<string, string | undefined>)[platform], platform);
    if (h && !out.some((m) => m.toLowerCase() === '@' + h.toLowerCase())) out.push('@' + h);
    if (out.length === 3) break;
  }
  return out;
}

/** "I'm going to X!" + mentions → "I'm going to X! with @org @promoter". */
export function withMentions(text: string, mentions: string[]): string {
  return mentions.length ? `${text} with ${mentions.join(' ')}` : text;
}

/** The organizer as a tag source (marketing.socials + marketing.allowTagging). */
export function orgTagSource(org: { marketing?: { socials?: Record<string, string | undefined>; allowTagging?: boolean } } | null | undefined): TagSource | null {
  if (!org?.marketing?.socials) return null;
  return { handles: org.marketing.socials, allowed: org.marketing.allowTagging !== false };
}
