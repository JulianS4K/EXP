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
  /** The changed request fields per listing (StubHub PATCH, SeatGeek PATCH, Gametime: the next file or POST /listings/{id}). */
  update: Array<{ listing_id: string; patch: Record<string, unknown> }>;
  delete: string[];
}

export type SyncedListings<P extends PlannedMarketplaceListings> = P & { action: SyncAction; ops: ListingOps };

export interface DelistPlan {
  action: 'delist';
  channel: 'stubhub' | 'seatgeek' | 'gametime';
  /** One request per listing (StubHub, Gametime) or one bulk request (SeatGeek). */
  requests: Array<{ endpoint: string; method: 'POST' | 'DELETE'; path: string; body?: unknown }>;
}

// Fields that describe the event, not the listing: fixed once listed.
const FIXED = new Set(['external_id', 'seller_listing_id', 'TicketID', 'event', 'venue', 'country', 'event_id']);

function changed(before: unknown, after: unknown): Record<string, unknown> {
  const b = (before ?? {}) as Record<string, unknown>;
  const a = (after ?? {}) as Record<string, unknown>;
  const patch: Record<string, unknown> = {};
  for (const k of Object.keys(a)) {
    if (FIXED.has(k)) continue;
    if (JSON.stringify(b[k]) !== JSON.stringify(a[k])) patch[k] = a[k];
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

/** Take down every Exos listing the marketplace has; null when it has none. */
export function planDelist(channel: DelistPlan['channel'], snapshot: unknown): DelistPlan | null {
  const ids = plannedEntries(snapshot).map((e) => e.listing_id).filter(isExosListingId);
  if (!ids.length) return null;
  const enc = encodeURIComponent;
  const requests: DelistPlan['requests'] = channel === 'seatgeek'
    ? [{ endpoint: 'bulkDeleteListings', method: 'POST', path: '/listings/bulk-delete', body: { seller_listing_ids: ids } }]
    : channel === 'stubhub'
      ? ids.map((id) => ({ endpoint: 'deleteSellerListingByExternalId', method: 'DELETE' as const, path: `/externalsellerlistings/${enc(id)}` }))
      : ids.map((id) => ({ endpoint: 'deleteListing', method: 'DELETE' as const, path: `/listings/${enc(id)}/delete` }));
  return { action: 'delist', channel, requests };
}
