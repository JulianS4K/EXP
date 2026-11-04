// The live ticket behind a partner's signed link (/t/:ticketId#k=<key>,
// mig 20261031130000, docs/partner-sales.md). The key is in the URL fragment,
// so it never reaches a server log; the page reads it here and asks
// exos_ticket_link_view for the current door code every 30 seconds.
//
// Pure helpers, tested in ticketLink.test.ts.

export const LINK_KEY_RE = /^[A-Za-z0-9_-]{43}$/;

/** The link key from a location hash ("#k=…", also "#…&k=…"), or null. */
export function linkKeyFromHash(hash: string): string | null {
  const params = new URLSearchParams(hash.replace(/^#/, ''));
  const k = params.get('k');
  return k && LINK_KEY_RE.test(k) ? k : null;
}

export type LinkState = 'valid' | 'checked_in' | 'voided' | 'in_transfer' | 'cancelled' | string;

export interface LinkView {
  ok: boolean;
  ticket_id?: string;
  state?: LinkState;
  event?: { name: string | null; starts_at: string | null; doors_at: string | null; timezone: string | null; venue_name: string | null; image_url: string | null };
  tier_name?: string | null;
  attendee_name?: string | null;
  code?: string | null;
  refresh_in_ms?: number;
  server_time?: string;
}

/** When to ask again: just after the code rotates (at least 2 s, at most 30 s). */
export function nextRefreshMs(view: Pick<LinkView, 'refresh_in_ms'>): number {
  const ms = Number(view.refresh_in_ms);
  if (!Number.isFinite(ms)) return 30_000;
  return Math.min(Math.max(ms + 250, 2_000), 30_000);
}

/** What the page says for a link that can't show a code. */
export function stateMessage(state: LinkState | undefined): string | null {
  switch (state) {
    case 'valid': return null;
    case 'checked_in': return 'Checked in. Enjoy the show.';
    case 'voided': return 'This ticket was cancelled.';
    case 'in_transfer': return 'This ticket is being transferred.';
    case 'cancelled': return 'This event was cancelled.';
    default: return 'This ticket can\'t be shown.';
  }
}
