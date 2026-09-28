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
  /** Pools (mig 20260928010000): the grid's cap, what's sold, what the listings show. */
  sell_cap?: number | null;
  sold_qty?: number | null;
  list_qty?: number | null;
  /**
   * Scarcity mode (mig 20260928040000), the computed field exos_pool_state:
   * closed (3 hours before doors) | stagnant | scarce | selling | normal | fixed.
   */
  exos_pool_state?: string | null;
}

/** What scarcity mode is doing with a pool, for the grid; null when nothing special. */
const POOL_STATE_NOTE: Record<string, string> = {
  selling: 'Selling: reloaded first',
  stagnant: 'No sale lately: not reloaded',
  scarce: 'Nearly sold out: holding one order\'s worth',
};

/** "Holding 4 now, up to 10 in total, 2 sold" for a grid cell, or null. */
export function poolLine(row: StubHubDistributionRow | null): string | null {
  if (!row || row.sell_cap == null || row.sell_cap <= 0 || row.status === 'delisted') return null;
  if (row.exos_pool_state === 'closed') {
    const back = row.requested_qty ? `; ${row.requested_qty} back to Exos once the listings are down` : '';
    return `Closed 3 hours before doors: Exos sells the rest at the door${back}.`;
  }
  const held = row.requested_qty ?? 0;
  const sold = row.sold_qty ?? 0;
  const parts = [`Holding ${held} now`, `up to ${row.sell_cap} in total`];
  if (sold) parts.push(`${sold} sold`);
  if (row.list_qty != null && row.list_qty < held) parts.push(`${held - row.list_qty} back to Exos once the marketplace takes the lower number`);
  else if (held === 0 && sold < row.sell_cap) parts.push('none free right now');
  const note = POOL_STATE_NOTE[row.exos_pool_state ?? ''];
  return parts.join(', ') + '.' + (note ? ` ${note}.` : '');
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

export type MarketplaceChannelId = 'stubhub' | 'seatgeek' | 'gametime' | 'gotickets' | 'vivid' | 'evo';
export const MARKETPLACE_LABEL: Record<MarketplaceChannelId, string> = {
  stubhub: 'StubHub', seatgeek: 'SeatGeek', gametime: 'Gametime', gotickets: 'GoTickets', vivid: 'Vivid Seats', evo: 'Ticket Evolution',
};

/** The event line for Vivid Seats: which Vivid event the listings attach to, or its mapping team. */
export function vividStatus(
  row: StubHubDistributionRow | null,
  ev: { ticked: boolean; published: boolean; primaryMarketOnly: boolean },
): StubHubStatus | null {
  if (!ev.ticked) return null;
  if (ev.primaryMarketOnly) return { tone: 'muted', text: 'Primary market only is on, so nothing goes to Vivid Seats.' };
  if (!row) {
    return ev.published
      ? { tone: 'muted', text: 'Save to queue Vivid Seats.' }
      : { tone: 'muted', text: 'Vivid Seats listings are planned when you publish.' };
  }
  switch (row.status) {
    case 'pending':
      return { tone: 'info', text: 'Queued: Exos is looking for this event on Vivid Seats.' };
    case 'planned':
      return row.planned_request?.linked
        ? { tone: 'ok', text: `Vivid Seats listings attach to Vivid event ${row.planned_request.external_event_id}.` }
        : { tone: 'info', text: "Not matched to a Vivid Seats event: Vivid's team maps the listings from the event name, venue and time, which can take a while. Not sent yet: Vivid Seats selling isn't switched on." };
    case 'failed':
      return { tone: 'warn', text: row.error || 'Vivid Seats: something needs a look.' };
    default:
      return { tone: 'muted', text: `Vivid Seats: ${row.status}.` };
  }
}

/** The event line for Ticket Evolution: its listings need TEvo's event, linked by Exos staff. */
export function tevoStatus(
  row: StubHubDistributionRow | null,
  ev: { ticked: boolean; published: boolean; primaryMarketOnly: boolean },
): StubHubStatus | null {
  if (!ev.ticked) return null;
  if (ev.primaryMarketOnly) return { tone: 'muted', text: 'Primary market only is on, so nothing goes to Ticket Evolution.' };
  if (!row) {
    return ev.published
      ? { tone: 'muted', text: 'Save to queue Ticket Evolution.' }
      : { tone: 'muted', text: 'Ticket Evolution listings are planned when you publish.' };
  }
  switch (row.status) {
    case 'pending':
      return { tone: 'info', text: 'Queued for Ticket Evolution.' };
    case 'planned':
      return row.planned_request?.linked
        ? { tone: 'ok', text: `Ticket Evolution listings attach to TEvo event ${row.planned_request.external_event_id}. Not sent yet: Ticket Evolution selling isn't switched on.` }
        : { tone: 'info', text: 'Ticket Evolution: waiting for Exos staff to link this event to its Ticket Evolution event.' };
    case 'failed':
      return { tone: 'warn', text: row.error || 'Ticket Evolution: something needs a look.' };
    default:
      return { tone: 'muted', text: `Ticket Evolution: ${row.status}.` };
  }
}

/** The event line for GoTickets: it maps listings to its own events. */
export function goTicketsStatus(
  row: StubHubDistributionRow | null,
  ev: { ticked: boolean; published: boolean; primaryMarketOnly: boolean },
): StubHubStatus | null {
  if (!ev.ticked) return null;
  if (ev.primaryMarketOnly) return { tone: 'muted', text: 'Primary market only is on, so nothing goes to GoTickets.' };
  if (!row) {
    return ev.published
      ? { tone: 'muted', text: 'Save to queue GoTickets.' }
      : { tone: 'muted', text: 'GoTickets listings are planned when you publish.' };
  }
  if (row.status === 'failed') return { tone: 'warn', text: row.error || 'GoTickets: something needs a look.' };
  return {
    tone: 'info',
    text: "GoTickets matches the listings to its event itself (name, venue, time, and the StubHub / SeatGeek event when linked). Not sent yet: GoTickets selling isn't switched on.",
  };
}

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
  if (row.status === 'delisted' || (qty <= 0 && !row.sell_cap)) return null;
  if (plan?.error) return { tone: 'warn', text: plan.error };
  if (row.error) return { tone: 'warn', text: row.error };
  if (row.status === 'listed' || row.status === 'listing') {
    const n = (plan?.ops?.create?.length ?? 0) + (plan?.ops?.update?.length ?? 0) + (plan?.ops?.delete?.length ?? 0);
    return { tone: 'ok', text: plan?.action === 'update' ? `On ${label}; ${n || 'some'} change${n === 1 ? '' : 's'} to send.` : `On ${label}.` };
  }
  if (!plan) return { tone: 'muted', text: `Held for ${label}; listed once the event is published.` };
  const listings = plan.listings?.length ?? 0;
  return {
    tone: 'info',
    text: `${listings} listing${listings === 1 ? '' : 's'} ready. Not sent yet: ${label} selling isn't switched on.`,
  };
}
