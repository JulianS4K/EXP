// The post kit: ONE composer for every social post and listing Exos plans
// (social phase, mig 20261121203000; docs/social.md "Posting and listing
// APIs"). From the event (exos_social_post_context) it builds each
// platform's title, text, link and image, with the organizer's warnings.
// The strings come from the event string source the discovery listings
// already use (discovery/copy.ts submissionCopy: the same title, date line,
// all-in price and plain-text description as the Google feed and the ad
// catalog), so an event reads the same everywhere. The image is the event's
// cover (catalog/feed.ts httpsUrl rules: https only); the story poster
// (src/lib/poster.ts) is a canvas render in the browser, offered in the
// panel for Stories posted by hand, never uploaded by Exos.
//
// Per platform:
//   instagram        caption, no link (links in captions aren't clickable):
//                    "Tickets: link in bio"; URLs in the description dropped
//   tiktok           title + description, no link; a URL is warned about
//                    (TikTok's ad-text rules, no URL / @ / #, apply to ads:
//                    adTextProblems); no QR code or contact info in the
//                    creative
//   meetup           title + description with the ticket link
//   linkedin         name + description with the ticket link
//   google_business  a short summary; the ticket link is the post's button
// A secret or TBA location is never posted: the venue line says the
// location goes to ticket holders and the address is left out.
//
// Pure: no Deno or Supabase imports (vitest imports it too).

import { submissionCopy, type CopyEventRow, type CopyTierRow } from "../discovery/copy.ts";
import { httpsUrl } from "../catalog/feed.ts";

export type SocialPlatform = "instagram" | "tiktok" | "meetup" | "linkedin" | "google_business";
export const SOCIAL_PLATFORMS: readonly SocialPlatform[] = ["instagram", "tiktok", "meetup", "linkedin", "google_business"];

export const PLATFORM_LABEL: Record<SocialPlatform, string> = {
  instagram: "Instagram",
  tiktok: "TikTok",
  meetup: "Meetup",
  linkedin: "LinkedIn",
  google_business: "Google Business Profile",
};

/** The event as exos_social_post_context returns it (the discovery event row + public tiers). */
export interface SocialEventInput extends CopyEventRow {
  status?: string | null;
  /** false: a secret / TBA location (nothing about the place is posted). */
  location_open?: boolean | null;
  tiers?: CopyTierRow[];
  org_name?: string | null;
}

export interface PlatformPost {
  platform: SocialPlatform;
  title: string;
  text: string;
  /** The ticket link (tagged per platform); null where the platform's text can't carry one. */
  url: string | null;
  imageUrl: string | null;
  videoUrl: string | null;
  startsAt: string | null;
  endsAt: string | null;
  timezone: string;
  /** Blank for a secret / TBA location. */
  venue: string;
  address: string;
  online: boolean;
  warnings: string[];
}

/** Text limits per platform (characters). Instagram's is documented; the rest are unverified. */
export const TEXT_LIMITS: Record<SocialPlatform, { title: number; text: number }> = {
  instagram: { title: 0, text: 2200 },
  tiktok: { title: 90, text: 4000 },
  meetup: { title: 80, text: 6000 },
  linkedin: { title: 255, text: 5000 },
  google_business: { title: 58, text: 1500 },
};

const URL_RE = /\b(?:https?:\/\/|www\.)[^\s)]+/gi;
const EMAIL_RE = /[^\s@]+@[^\s@]+\.[a-z]{2,}/i;
const PHONE_RE = /(?:\+?\d[\s().-]?){10,}/;
export const SECRET_VENUE_LINE = "Location shared with ticket holders";

const clip = (s: string, n: number): string => (n > 0 && s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);
const lines = (...xs: Array<string | null | undefined | false>) => xs.filter((x): x is string => !!x && x.trim() !== "").join("\n");

export const hasUrl = (s: string): boolean => new RegExp(URL_RE.source, "i").test(s);
export const stripUrls = (s: string): string => s.replace(URL_RE, "").replace(/[ \t]{2,}/g, " ").replace(/\s+([.,;:])/g, "$1").trim();

/**
 * TikTok's ad-text rules (operator brief 2026-11-21): no URL, no @ and no #
 * in ad text. For organic posts these are warnings only (see the kit).
 */
export function adTextProblems(text: string): string[] {
  const out: string[] = [];
  if (hasUrl(text)) out.push("a link");
  if (/@\w/.test(text) && !EMAIL_RE.test(text)) out.push("an @ mention");
  else if (/@/.test(text)) out.push("an @");
  if (/#\w/.test(text)) out.push("a hashtag");
  return out;
}

/** Contact details in text (TikTok creatives may not carry them). */
export function contactInfoProblems(text: string): string[] {
  const out: string[] = [];
  if (EMAIL_RE.test(text)) out.push("an email address");
  if (PHONE_RE.test(text)) out.push("a phone number");
  return out;
}

export interface KitOptions {
  appBase: string;
  now?: Date;
}

/** One platform's post. */
export function composePost(ev: SocialEventInput, platform: SocialPlatform, opts: KitOptions): PlatformPost {
  const now = opts.now ?? new Date();
  const open = ev.location_open !== false;
  const online = ev.format === "online";
  // The shared strings, with a secret location's venue never in them.
  const row: CopyEventRow = { ...ev, venue_name: open ? ev.venue_name : null, venue_address: open ? ev.venue_address : null };
  const copy = submissionCopy(row, ev.tiers ?? [], platform, opts.appBase, now);
  const venue = online ? "Online" : open ? copy.venue : SECRET_VENUE_LINE;
  const address = open && !online ? copy.address : "";
  const where = [venue, address].filter(Boolean).join(", ");
  const priceLine = copy.price ? `Tickets: ${copy.price} (all-in)` : "";
  const imageUrl = httpsUrl(ev.image_url);
  const lim = TEXT_LIMITS[platform];
  const warnings: string[] = [];
  if (ev.status && ev.status !== "published") warnings.push("The event isn't published yet: people would find a page they can't open.");
  if (!open) warnings.push("The location is secret or TBA: the post says it is shared with ticket holders, and no address is posted.");
  const base = {
    platform, imageUrl, videoUrl: null, startsAt: ev.starts_at ?? null, endsAt: ev.ends_at ?? null,
    timezone: ev.timezone || "UTC", venue: open || online ? venue : "", address, online,
  };

  if (platform === "instagram") {
    const desc = stripUrls(copy.description);
    if (desc !== copy.description.trim()) warnings.push("Links in the description were left out: Instagram captions can't carry a clickable link.");
    if (!imageUrl) warnings.push("Instagram posts need an image: add one to the event.");
    else if (!/\.jpe?g(?:$|[?#])/i.test(imageUrl)) warnings.push("Instagram takes JPEG images only (unverified for every format): the event image may be refused.");
    const tail = "Tickets: link in bio.";
    const head = lines(copy.title, copy.when, where, priceLine);
    const body = clip(desc, Math.max(0, lim.text - head.length - tail.length - 4));
    return { ...base, title: copy.title, text: lines(head, "", body, "", tail).replace(/\n{3,}/g, "\n\n"), url: null, warnings };
  }

  if (platform === "tiktok") {
    if (hasUrl(copy.description)) warnings.push("The description has a link: TikTok posts can't carry a clickable link, and TikTok's ad text allows no URL, @ or #.");
    const contact = contactInfoProblems(copy.description);
    if (contact.length) warnings.push(`The description has ${contact.join(" and ")}: TikTok creatives may not carry contact details.`);
    warnings.push("The image must not show a QR code or contact details (TikTok's rule): use the event art, not the story poster with the link printed on it.");
    if (!imageUrl) warnings.push("TikTok photo posts need an image: add one to the event.");
    const text = clip(lines(copy.when, where, priceLine, "", copy.description, "", "Tickets: link in bio.").replace(/\n{3,}/g, "\n\n"), lim.text);
    return { ...base, title: clip(copy.title, lim.title), text, url: null, warnings };
  }

  if (platform === "google_business") {
    const summary = clip(lines([copy.when, where].filter(Boolean).join(" · "), priceLine, copy.description).replace(/\n/g, " "), lim.text);
    if (PHONE_RE.test(summary)) warnings.push("The text has a phone number: Google may reject a post with one (unverified).");
    return { ...base, title: clip(copy.title, lim.title), text: summary, url: copy.ticketLink, warnings };
  }

  // meetup, linkedin: a listing, the ticket link in the text.
  const text = clip(lines(copy.description, "", priceLine, `Get tickets: ${copy.ticketLink}`).replace(/\n{3,}/g, "\n\n"), lim.text);
  return { ...base, title: clip(copy.title, lim.title), text, url: copy.ticketLink, warnings };
}

/** Every platform's post, from one event. */
export function composePostKit(ev: SocialEventInput, opts: KitOptions, platforms: readonly SocialPlatform[] = SOCIAL_PLATFORMS): PlatformPost[] {
  return platforms.map((p) => composePost(ev, p, opts));
}
