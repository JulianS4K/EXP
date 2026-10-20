// "Back" buttons for pages people often open straight from a link (an
// Instagram story, a text, an email). navigate(-1) there leaves the site, so
// go back only when there is an in-app page to go back to; otherwise go to a
// sensible page of ours.

/** React Router keeps the in-app history position in history.state.idx (0 on
 *  the first page of this visit). */
export function hasInAppHistory(state: unknown = typeof window !== 'undefined' ? window.history.state : null): boolean {
  const idx = (state as { idx?: unknown } | null)?.idx;
  return typeof idx === 'number' && idx > 0;
}

/** Where "back to events" goes without in-app history: the organizer's
 *  storefront when known, else the home page. */
export function backFallback(orgSlug?: string | null): string {
  const slug = (orgSlug ?? '').trim();
  return slug ? `/o/${encodeURIComponent(slug)}` : '/';
}
