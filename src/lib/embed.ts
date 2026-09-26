// Venue-site embed (white-label level 3): pure helpers shared by the embed
// views (/embed/event/:id, /embed/return), the organizer's snippet box, and
// mirrored by the loader in public/embed.js.
//
// Message protocol (iframe → host page), always posted to the host's exact
// origin, never '*':
//   { type: 'exos:resize', height }                      content height in px
//   { type: 'exos:checkout-complete', eventId, sessionId? } a checkout finished
// The host origin reaches the iframe as ?host=<origin> (set by embed.js). A
// wrong ?host= only means the browser drops our messages: postMessage with a
// target origin is delivered only if the parent really has that origin.
//
// Old copy-paste snippets (iframe + inline listener) have no ?host= and listen
// for { type: 'vibepass:resize' }; they keep getting that (height only, to '*')
// and nothing else.

export const EMBED_RESIZE = 'exos:resize';
export const EMBED_COMPLETE = 'exos:checkout-complete';
export const LEGACY_RESIZE = 'vibepass:resize';

const ID_RE = /^[A-Za-z0-9-]{1,64}$/;

/** A bare http(s) origin ("https://venue.com"), or null. http only for localhost. */
export function parseHostOrigin(raw: string | null | undefined): string | null {
  if (!raw || raw.length > 300) return null;
  let u: URL;
  try { u = new URL(raw); } catch { return null; }
  if (u.username || u.password) return null;
  const local = u.hostname === 'localhost' || u.hostname === '127.0.0.1';
  if (u.protocol !== 'https:' && !(u.protocol === 'http:' && local)) return null;
  // Must be exactly an origin, not a page URL.
  if (raw.replace(/\/$/, '') !== u.origin) return null;
  return u.origin;
}

/** Where the iframe may post sensitive-ish messages: ?host=, else the real
 *  ancestor origin when the browser tells us (Chrome/Safari), else null. */
export function resolveHostOrigin(
  search: string,
  ancestorOrigins?: ArrayLike<string> | null,
): string | null {
  const fromParam = parseHostOrigin(new URLSearchParams(search).get('host'));
  if (fromParam) return fromParam;
  const first = ancestorOrigins && ancestorOrigins.length > 0 ? ancestorOrigins[0] : null;
  return parseHostOrigin(first);
}

export type EmbedMessage =
  | { type: typeof EMBED_RESIZE; height: number }
  | { type: typeof EMBED_COMPLETE; eventId: string; sessionId?: string };

/** Validate a message's payload (the host side checks origin + source first). */
export function parseEmbedMessage(data: unknown): EmbedMessage | null {
  if (!data || typeof data !== 'object') return null;
  const d = data as Record<string, unknown>;
  if (d.type === EMBED_RESIZE) {
    const h = d.height;
    if (typeof h !== 'number' || !Number.isFinite(h) || h < 0 || h > 20000) return null;
    return { type: EMBED_RESIZE, height: Math.ceil(h) };
  }
  if (d.type === EMBED_COMPLETE) {
    if (typeof d.eventId !== 'string' || !ID_RE.test(d.eventId)) return null;
    const out: EmbedMessage = { type: EMBED_COMPLETE, eventId: d.eventId };
    if (typeof d.sessionId === 'string' && /^cs_[A-Za-z0-9_]{1,255}$/.test(d.sessionId)) out.sessionId = d.sessionId;
    return out;
  }
  return null;
}

/** Post to the host page. Resize falls back to the legacy '*' message when the
 *  host is unknown (height only); anything else is dropped without a host. */
export function postToHost(msg: EmbedMessage, host: string | null, target: Pick<Window, 'postMessage'> | null): boolean {
  if (!target) return false;
  try {
    if (host) {
      target.postMessage(msg, host);
      return true;
    }
    if (msg.type === EMBED_RESIZE) {
      target.postMessage({ type: LEGACY_RESIZE, height: msg.height }, '*');
      return true;
    }
  } catch {
    /* parent gone / cross-origin quirk: no-op */
  }
  return false;
}

/** Stripe Embedded Checkout return_url for this iframe. `{CHECKOUT_SESSION_ID}`
 *  must stay literal (Stripe substitutes it), so it isn't URL-encoded. */
export function buildEmbedReturnUrl(returnPageUrl: string, eventId: string, host: string | null): string {
  const q = [`session_id={CHECKOUT_SESSION_ID}`, `event=${encodeURIComponent(eventId)}`];
  if (host) q.push(`host=${encodeURIComponent(host)}`);
  return `${returnPageUrl}?${q.join('&')}`;
}

/** The paste-ready snippet for a venue's site. `loaderUrl` = our /embed.js. */
export function buildEmbedSnippet(input: { loaderUrl: string; eventId: string; title?: string }): string {
  const id = ID_RE.test(input.eventId) ? input.eventId : 'EVENT_ID';
  // The title goes inside an HTML comment: strip anything that could close it.
  const title = (input.title ?? '').replace(/-{2,}/g, '—').replace(/[<>]/g, '').slice(0, 120).trim();
  const loader = input.loaderUrl.replace(/"/g, '%22');
  return `<!-- Exos tickets${title ? ` — ${title}` : ''} -->
<div data-exos-event="${id}"></div>
<script src="${loader}" async></script>`;
}

export type EmbedTier = {
  id: string;
  price: number;
  capacity: number;
  sold: number;
  visibility?: 'public' | 'hidden';
  salesStart?: { toMillis: () => number } | null;
  salesEnd?: { toMillis: () => number } | null;
};

/** Tiers a fan can pick in the embed right now: public, inside the sale
 *  window, not sold out (capacity 0 = unlimited). */
export function buyableTiers<T extends EmbedTier>(tiers: T[] | undefined, now = Date.now()): T[] {
  return (tiers ?? []).filter((t) => {
    if ((t.visibility ?? 'public') !== 'public') return false;
    if (t.salesStart && t.salesStart.toMillis() > now) return false;
    if (t.salesEnd && t.salesEnd.toMillis() < now) return false;
    if (t.capacity > 0 && (t.sold || 0) >= t.capacity) return false;
    return true;
  });
}

/** Most tickets the picker offers for a tier (exos-checkout caps at 10). */
export function maxQuantity(tier: EmbedTier, maxPerOrder?: number | null): number {
  const perOrder = Math.min(10, maxPerOrder && maxPerOrder > 0 ? maxPerOrder : 8);
  if (tier.capacity > 0) return Math.max(0, Math.min(perOrder, tier.capacity - (tier.sold || 0)));
  return perOrder;
}
