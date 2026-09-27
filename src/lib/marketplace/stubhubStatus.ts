// What the event editor says about an event's StubHub event request
// (exos_distribution_listings, channel 'stubhub'; mig 20260926190000).
// Pure, so the wording is tested without a database.

export interface StubHubDistributionRow {
  status: string;
  /** Seats allocated to StubHub (mig 20260926193000): Exos can't sell these. */
  tier_id?: string | null;
  requested_qty?: number | null;
  error: string | null;
  external_event_id: string | null;
  planned_request: {
    /** Linked to an event StubHub already has: nothing to create. */
    linked?: boolean;
    external_event_id?: string;
    body?: { event?: { name?: string }; venue?: { name?: string; city?: string } };
  } | null;
  last_synced_at: string | null;
  /** The listing(s) exos-distribute would create / update / delist (migs 20260926194000, 20260927030000), or { error }. */
  planned_listing?: unknown;
  /** Internal seat numbers of the unsold allocated seats ("{[1,11)}"); staff only. */
  internal_seats?: string | null;
}

/** An event's rows on one marketplace: the event row, and an allocation per ticket type. */
export interface MarketplaceRow extends StubHubDistributionRow {
  channel: string;
}

export type StubHubStatusTone = 'muted' | 'info' | 'ok' | 'warn';

export interface StubHubStatus {
  tone: StubHubStatusTone;
  text: string;
}

export function stubHubStatus(
  row: StubHubDistributionRow | null,
  ev: { stubhubTicked: boolean; published: boolean; primaryMarketOnly: boolean },
): StubHubStatus | null {
  if (row?.external_event_id) return { tone: 'ok', text: `On StubHub (event ${row.external_event_id}).` };
  if (!ev.stubhubTicked) return null;
  if (ev.primaryMarketOnly) return { tone: 'muted', text: 'Primary market only is on, so nothing goes to StubHub.' };
  if (!row) {
    return ev.published
      ? { tone: 'muted', text: 'Save to queue the StubHub event request.' }
      : { tone: 'muted', text: 'The StubHub event is requested when you publish.' };
  }
  switch (row.status) {
    case 'pending':
      return { tone: 'info', text: 'Queued: Exos is preparing the StubHub event request.' };
    case 'planned': {
      if (row.planned_request?.linked) {
        return { tone: 'ok', text: `Already on StubHub (event ${row.planned_request.external_event_id}): no new event needed.` };
      }
      const b = row.planned_request?.body;
      const what = [b?.event?.name, [b?.venue?.name, b?.venue?.city].filter(Boolean).join(', ')].filter(Boolean).join(' at ');
      return {
        tone: 'info',
        text: `StubHub event request ready${what ? ` for ${what}` : ''}. Not sent yet: StubHub selling isn't switched on.`,
      };
    }
    case 'failed':
      return { tone: 'warn', text: `Couldn't prepare the StubHub request: ${row.error || 'unknown error'}. Fix it and save.` };
    default:
      return { tone: 'muted', text: `StubHub: ${row.status}.` };
  }
}

export type MarketplaceChannelId = 'stubhub' | 'seatgeek' | 'gametime';
export const MARKETPLACE_LABEL: Record<MarketplaceChannelId, string> = { stubhub: 'StubHub', seatgeek: 'SeatGeek', gametime: 'Gametime' };

/** The event line for Gametime: no event search or creation, and listings go up as a file. */
export function gametimeStatus(
  row: StubHubDistributionRow | null,
  ev: { ticked: boolean; published: boolean; primaryMarketOnly: boolean },
): StubHubStatus | null {
  if (!ev.ticked) return null;
  if (ev.primaryMarketOnly) return { tone: 'muted', text: 'Primary market only is on, so nothing goes to Gametime.' };
  if (!row) {
    return ev.published
      ? { tone: 'muted', text: 'Save to queue Gametime.' }
      : { tone: 'muted', text: 'Gametime listings are planned when you publish.' };
  }
  if (row.status === 'failed') return { tone: 'warn', text: row.error || 'Gametime: something needs a look.' };
  return {
    tone: 'info',
    text: "Gametime matches listings on the event name, venue and date. They go up in Gametime's inventory file; not sent yet: Gametime selling isn't switched on.",
  };
}

/** The event line for SeatGeek, which has no event creation: which event the listings attach to. */
export function seatGeekStatus(
  row: StubHubDistributionRow | null,
  ev: { ticked: boolean; published: boolean; primaryMarketOnly: boolean },
): StubHubStatus | null {
  if (!ev.ticked) return null;
  if (ev.primaryMarketOnly) return { tone: 'muted', text: 'Primary market only is on, so nothing goes to SeatGeek.' };
  if (!row) {
    return ev.published
      ? { tone: 'muted', text: 'Save to queue SeatGeek.' }
      : { tone: 'muted', text: 'SeatGeek listings are planned when you publish.' };
  }
  switch (row.status) {
    case 'pending':
      return { tone: 'info', text: 'Queued: Exos is looking for this event on SeatGeek.' };
    case 'planned':
      return row.planned_request?.linked
        ? { tone: 'ok', text: `SeatGeek listings attach to SeatGeek event ${row.planned_request.external_event_id}.` }
        : { tone: 'info', text: "Not matched to a SeatGeek event: listings carry the event name and venue for SeatGeek to match. SeatGeek can't create events." };
    case 'failed':
      return { tone: 'warn', text: row.error || 'SeatGeek: something needs a look.' };
    default:
      return { tone: 'muted', text: `SeatGeek: ${row.status}.` };
  }
}

interface PlanShape {
  error?: string;
  action?: string;
  listings?: unknown[];
  ops?: { create?: unknown[]; update?: unknown[]; delete?: unknown[] };
  unresolved?: string[];
}

/** One cell of the Marketplaces grid: what's happening with this ticket type there. */
export function allocationCellStatus(row: StubHubDistributionRow | null, channel: MarketplaceChannelId): StubHubStatus | null {
  if (!row) return null;
  const label = MARKETPLACE_LABEL[channel];
  const plan = (row.planned_listing ?? null) as PlanShape | null;
  const qty = row.requested_qty ?? 0;
  if (row.status === 'delisting') return { tone: 'warn', text: `Coming off ${label}; the seats return to Exos once it's down.` };
  if (row.status === 'delisted' || qty <= 0) return null;
  if (plan?.error) return { tone: 'warn', text: plan.error };
  if (row.error) return { tone: 'warn', text: row.error };
  if (row.status === 'listed' || row.status === 'listing') {
    const n = (plan?.ops?.create?.length ?? 0) + (plan?.ops?.update?.length ?? 0) + (plan?.ops?.delete?.length ?? 0);
    return { tone: 'ok', text: plan?.action === 'update' ? `On ${label}; ${n || 'some'} change${n === 1 ? '' : 's'} to send.` : `On ${label}.` };
  }
  if (!plan) return { tone: 'muted', text: `Held for ${label}; listed once the event is published.` };
  const listings = channel === 'stubhub' ? 1 : plan.listings?.length ?? 0;
  return {
    tone: 'info',
    text: `${listings} listing${listings === 1 ? '' : 's'} ready. Not sent yet: ${label} selling isn't switched on.`,
  };
}
