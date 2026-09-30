// Formats of the public pixel / tag ids an organizer pastes into Settings →
// Marketing (exos_orgs.marketing.pixels). They're public ids, never secrets,
// and they end up in script URLs and vendor calls, so the editor refuses
// anything that doesn't look like the vendor's id, and the loaders in
// lib/pixels.ts skip a malformed Reddit / Snap / X id.
//
// Kept loose on purpose where vendors have changed their format over time
// (Meta ids are 15-16 digits today; older TikTok ids aren't all 20 chars).

export type PixelKey =
  | 'meta' | 'ga4' | 'tiktok' | 'reddit' | 'snap' | 'x'
  | 'xViewContent' | 'xInitiateCheckout' | 'xPurchase';

const RULES: Record<PixelKey, { re: RegExp; example: string }> = {
  // Meta Pixel / dataset id: digits.
  meta: { re: /^[0-9]{10,20}$/, example: '123456789012345' },
  // GA4 measurement id.
  ga4: { re: /^G-[A-Z0-9]{4,16}$/, example: 'G-ABC123XYZ9' },
  // TikTok pixel code: upper-case letters and digits (usually 20, starting C).
  tiktok: { re: /^[A-Z0-9]{10,32}$/, example: 'C4ABCDEFGHIJKLMNOPQR' },
  // Reddit pixel id: the ad account id, a2_… (older accounts t2_…).
  reddit: { re: /^(a2|t2)_[a-z0-9]{3,32}$/i, example: 'a2_abc123def456' },
  // Snap Pixel id: a UUID.
  snap: { re: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, example: '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d' },
  // X pixel id (the id in twq('config', …)).
  x: { re: /^[a-z0-9]{4,12}$/i, example: 'o8z6j' },
  // X event ids (Events Manager): tw-<pixel id>-<event>.
  xViewContent: { re: /^tw-[a-z0-9]{4,12}-[a-z0-9]{4,12}$/i, example: 'tw-o8z6j-o8z21' },
  xInitiateCheckout: { re: /^tw-[a-z0-9]{4,12}-[a-z0-9]{4,12}$/i, example: 'tw-o8z6j-o8z22' },
  xPurchase: { re: /^tw-[a-z0-9]{4,12}-[a-z0-9]{4,12}$/i, example: 'tw-o8z6j-o8z23' },
};

export function pixelIdExample(key: PixelKey): string {
  return RULES[key].example;
}

/** True for an empty value (not set) or a well-formed id. */
export function isValidPixelId(key: PixelKey, value: string | undefined | null): boolean {
  const v = (value ?? '').trim();
  return v === '' || RULES[key].re.test(v);
}

/** The id if it's well-formed, else undefined. */
export function cleanPixelId(key: PixelKey, value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const v = value.trim();
  return v && RULES[key].re.test(v) ? v : undefined;
}

/** The keys in `pixels` whose value is set but malformed. */
export function invalidPixelKeys(pixels: Partial<Record<PixelKey, string>> | undefined): PixelKey[] {
  if (!pixels) return [];
  return (Object.keys(RULES) as PixelKey[]).filter((k) => !isValidPixelId(k, pixels[k]));
}

/** An X event id must belong to the configured X pixel (tw-<pixel>-…). */
export function xEventMatchesPixel(pixel: string | undefined, eventId: string | undefined): boolean {
  if (!pixel || !eventId) return true;
  return eventId.toLowerCase().startsWith(`tw-${pixel.toLowerCase()}-`);
}
