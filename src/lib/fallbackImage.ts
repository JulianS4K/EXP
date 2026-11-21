// The neutral picture for an event or storefront with no artwork of its own
// (UX quick wins, 2026-11-21). Was a hot-linked Unsplash photo: a third-party
// request on every such page, a stranger's photo standing in for the event,
// and a broken tile whenever the host said no. This is an inline SVG (a dark
// gradient with a faint halftone, matching the xerox look) as a data: URI,
// which every page's CSP already allows (img-src data:). Nothing to fetch.

const SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 900" preserveAspectRatio="xMidYMid slice">' +
  '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">' +
  '<stop offset="0" stop-color="#1c1c1c"/><stop offset=".55" stop-color="#101010"/><stop offset="1" stop-color="#262626"/>' +
  '</linearGradient><pattern id="d" width="12" height="12" patternUnits="userSpaceOnUse">' +
  '<circle cx="6" cy="6" r="1.4" fill="#fff" fill-opacity=".06"/></pattern></defs>' +
  '<rect width="1200" height="900" fill="url(#g)"/><rect width="1200" height="900" fill="url(#d)"/>' +
  '<path d="M0 720 L1200 520 L1200 900 L0 900 Z" fill="#fff" fill-opacity=".03"/></svg>';

export const FALLBACK_EVENT_IMAGE = `data:image/svg+xml,${encodeURIComponent(SVG)}`;

/** The event's own image when it has one (https or a local path), else the fallback. */
export function eventImageOr(url: string | null | undefined): string {
  const u = (url ?? '').trim();
  return u ? u : FALLBACK_EVENT_IMAGE;
}
