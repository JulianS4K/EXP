// Keeping a marketplace's listings in step with an allocation (migs
// 20260927030000 / 040000). Pure: exos-distribute stores the result in
// exos_distribution_listings.planned_listing, and nothing is sent while
// marketplace writes are dry-run (CLAUDE.md Hard Rule #2).
//
// One diff for every marketplace: plans share one shape (../exosListing.ts,
// PlannedMarketplaceListings), keyed by the Exos listing id.
// listed_snapshot is what the marketplace has now (the listings as last
// sent). With none, everything is a create. With one, new listings are
// created, changed ones updated, and ones that are gone (sold out, dropped
// by a smaller allocation) deleted. An allocation being pulled back
// ('delisting') gets a delist of everything the marketplace has; its seats
// return to Exos once that has gone through.

import { plannedEntries, type PlannedMarketplaceListings } from './exosListing.ts';
import { isExosListingId } from './listingIds.ts';

export type SyncAction = 'create' | 'update' | 'none' | 'delist';

export interface ListingOps {
  create: string[];
  /**
   * The changed request fields per listing (StubHub PATCH, SeatGeek PATCH,
   * Gametime: the next file or POST /listings/{id}; Ticket Evolution PATCH
   * /v9/inventory/{id}: {inventory: {ticket: changed fields}}).
   */
  update: Array<{ listing_id: string; patch: Record<string, unknown> }>;
  delete: string[];
}

export type SyncedListings<P extends PlannedMarketplaceListings> = P & { action: SyncAction; ops: ListingOps };

export interface DelistPlan {
  action: 'delist';
  channel: 'stubhub' | 'seatgeek' | 'gametime' | 'gotickets' | 'vivid' | 'evo';
  /** One request per listing (StubHub, Gametime, Vivid Seats, Ticket Evolution), or in bulk (SeatGeek; GoTickets 100 at a time). */
  requests: Array<{ endpoint: string; method: 'POST' | 'DELETE'; path: string; body?: unknown }>;
}

// Fields that describe the event (or whose listing it is), not the listing: fixed once listed.
const FIXED = new Set(['external_id', 'seller_listing_id', 'TicketID', 'event', 'venue', 'country', 'event_id', 'office', 'remote_id', 'internal_notes']);
// Wrappers diffed field by field (Ticket Evolution's {inventory: {ticket: …}}).
const NESTED = new Set(['inventory', 'ticket']);

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

function changed(before: unknown, after: unknown): Record<string, unknown> {
  const b = (before ?? {}) as Record<string, unknown>;
  const a = (after ?? {}) as Record<string, unknown>;
  const patch: Record<string, unknown> = {};
  for (const k of Object.keys(a)) {
    if (FIXED.has(k)) continue;
    if (NESTED.has(k) && isObj(a[k]) && isObj(b[k])) {
      const inner = changed(b[k], a[k]);
      if (Object.keys(inner).length) patch[k] = inner;
    } else if (JSON.stringify(b[k]) !== JSON.stringify(a[k])) patch[k] = a[k];
  }
  return patch;
}

/** The plan, diffed against what the marketplace has (null: nothing yet). */
export function syncListings<P extends PlannedMarketplaceListings>(plan: P, snapshot: unknown): SyncedListings<P> {
  const live = snapshot == null ? null : new Map(plannedEntries(snapshot).map((e) => [e.listing_id, e]));
  const ops: ListingOps = { create: [], update: [], delete: [] };
  for (const l of plan.listings) {
    const had = live?.get(l.listing_id);
    if (!had) {
      ops.create.push(l.listing_id);
      continue;
    }
    const patch = changed(had.request?.body, l.request.body);
    if (Object.keys(patch).length) ops.update.push({ listing_id: l.listing_id, patch });
  }
  if (live) {
    const planned = new Set(plan.listings.map((l) => l.listing_id));
    for (const id of live.keys()) if (!planned.has(id) && isExosListingId(id)) ops.delete.push(id);
  }
  const action: SyncAction = !live ? 'create' : ops.create.length || ops.update.length || ops.delete.length ? 'update' : 'none';
  return { ...plan, action, ops };
}

/**
 * TEvo's id for an Exos listing it has: the live sender records it on the
 * snapshot entry (tevo_inventory_id, from Inventory / Create's 201).
 */
function tevoInventoryId(e: unknown): string | null {
  const v = (e as { tevo_inventory_id?: unknown } | null)?.tevo_inventory_id;
  const s = typeof v === 'number' || typeof v === 'string' ? String(v).trim() : '';
  return /^[1-9]\d*$/.test(s) ? s : null;
}

/** Take down every Exos listing the marketplace has; null when it has none. */
export function planDelist(channel: DelistPlan['channel'], snapshot: unknown): DelistPlan | null {
  const entries = plannedEntries(snapshot).filter((e) => isExosListingId(e.listing_id));
  const ids = entries.map((e) => e.listing_id);
  if (!ids.length) return null;
  if (channel === 'evo') {
    // By TEvo id, one at a time (bulk delete is forbidden); an entry without
    // one can't be addressed safely and waits for a person.
    return {
      action: 'delist',
      channel,
      requests: entries.map((e) => {
        const id = tevoInventoryId(e);
        return id
          ? { endpoint: 'deleteInventory', method: 'DELETE' as const, path: `/v9/inventory/${id}` }
          : { endpoint: 'deleteInventory', method: 'DELETE' as const, path: `/v9/inventory/{no TEvo id recorded for ${e.listing_id}: take it down by hand}` };
      }),
    };
  }
  const enc = encodeURIComponent;
  const chunks = (n: number) => Array.from({ length: Math.ceil(ids.length / n) }, (_, i) => ids.slice(i * n, i * n + n));
  const requests: DelistPlan['requests'] = channel === 'seatgeek'
    ? [{ endpoint: 'bulkDeleteListings', method: 'POST', path: '/listings/bulk-delete', body: { seller_listing_ids: ids } }]
    : channel === 'gotickets'
      // By external id only, 100 per request.
      ? chunks(100).map((c) => ({ endpoint: 'deleteListingsByExternalIds', method: 'DELETE' as const, path: '/rest/listings/external-id', body: c }))
    : channel === 'vivid'
      // By our ticketId only, never Vivid's listingId.
      ? ids.map((id) => ({ endpoint: 'deleteListing', method: 'DELETE' as const, path: `/listings/v2/delete?internalTicketId=${enc(id)}` }))
    : channel === 'stubhub'
      ? ids.map((id) => ({ endpoint: 'deleteSellerListingByExternalId', method: 'DELETE' as const, path: `/externalsellerlistings/${enc(id)}` }))
      : ids.map((id) => ({ endpoint: 'deleteListing', method: 'DELETE' as const, path: `/listings/${enc(id)}/delete` }));
  return { action: 'delist', channel, requests };
}
