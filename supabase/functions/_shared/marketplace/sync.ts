// Keeping a marketplace's listings in step with an allocation (mig
// 20260927030000). Pure: exos-distribute stores the result in
// exos_distribution_listings.planned_listing, and nothing is sent while
// marketplace writes are dry-run (CLAUDE.md Hard Rule #2).
//
// listed_snapshot is what the marketplace has now (the listings as last
// sent). With none, everything is a create. With one, the plan is diffed
// against it: new listings are created, changed ones updated, and ones that
// are gone (sold out, dropped by a smaller allocation) deleted. An
// allocation being pulled back ('delisting') gets a delist of everything the
// marketplace has; its seats return to Exos once that has gone through.

import type { PlannedListing } from './stubhub/listingPlan.ts';
import type { PlannedSeatGeekListings } from './seatgeek/listingPlan.ts';
import { isExosSellerListingId } from './seatgeek/listingPlan.ts';

export type SyncAction = 'create' | 'update' | 'none' | 'delist';

type SgListing = PlannedSeatGeekListings['listings'][number];

export interface SeatGeekSyncPlan extends PlannedSeatGeekListings {
  action: SyncAction;
  ops: {
    create: string[];
    update: Array<{ seller_listing_id: string; patch: Record<string, unknown> }>;
    delete: string[];
  };
}

export interface StubHubSyncPlan extends PlannedListing {
  action: SyncAction;
  /** For an update: PATCH /externalsellerlistings/{external_id} with only what changed. */
  update?: { endpoint: 'updateSellerListingByExternalId'; method: 'PATCH'; path: string; body: Record<string, unknown> };
}

export interface DelistPlan {
  action: 'delist';
  endpoint: 'bulkDeleteListings' | 'deleteSellerListingByExternalId';
  method: 'POST' | 'DELETE';
  path: string;
  body?: { seller_listing_ids: string[] };
}

/** The SeatGeek listing bodies in a stored snapshot / plan ({ listings: [{ body }] }). */
export function seatGeekListingBodies(v: unknown): Array<SgListing['body']> {
  const ls = (v as { listings?: unknown } | null)?.listings;
  if (!Array.isArray(ls)) return [];
  return ls
    .map((l) => (l as { body?: SgListing['body'] } | null)?.body)
    .filter((b): b is SgListing['body'] => !!b && typeof b.seller_listing_id === 'string');
}

function changed(before: Record<string, unknown>, after: Record<string, unknown>, skip: string[]): Record<string, unknown> {
  const patch: Record<string, unknown> = {};
  for (const k of Object.keys(after)) {
    if (skip.includes(k)) continue;
    if (JSON.stringify(before[k]) !== JSON.stringify(after[k])) patch[k] = after[k];
  }
  return patch;
}

export function seatGeekSync(plan: PlannedSeatGeekListings, snapshot: unknown): SeatGeekSyncPlan {
  const live = snapshot == null ? null : new Map(seatGeekListingBodies(snapshot).map((b) => [b.seller_listing_id, b]));
  const ops: SeatGeekSyncPlan['ops'] = { create: [], update: [], delete: [] };
  for (const l of plan.listings) {
    const had = live?.get(l.body.seller_listing_id);
    if (!had) {
      ops.create.push(l.body.seller_listing_id);
      continue;
    }
    const patch = changed(had as unknown as Record<string, unknown>, l.body as unknown as Record<string, unknown>, ['seller_listing_id']);
    if (Object.keys(patch).length) ops.update.push({ seller_listing_id: l.body.seller_listing_id, patch });
  }
  if (live) {
    const planned = new Set(plan.listings.map((l) => l.body.seller_listing_id));
    for (const id of live.keys()) if (!planned.has(id) && isExosSellerListingId(id)) ops.delete.push(id);
  }
  const action: SyncAction = !live ? 'create' : ops.create.length || ops.update.length || ops.delete.length ? 'update' : 'none';
  return { ...plan, action, ops };
}

export function seatGeekDelist(snapshot: unknown): DelistPlan | null {
  const ids = seatGeekListingBodies(snapshot).map((b) => b.seller_listing_id).filter(isExosSellerListingId);
  if (!ids.length) return null;
  return { action: 'delist', endpoint: 'bulkDeleteListings', method: 'POST', path: '/listings/bulk-delete', body: { seller_listing_ids: ids } };
}

// StubHub fields that describe the event, not the listing: fixed once listed.
const STUBHUB_FIXED = ['external_id', 'event', 'venue', 'country', 'event_id'];

export function stubHubSync(plan: PlannedListing, snapshot: unknown, allocationId: string): StubHubSyncPlan {
  const had = (snapshot as { body?: Record<string, unknown> } | null)?.body;
  if (!had) return { ...plan, action: 'create' };
  const patch = changed(had, plan.body, STUBHUB_FIXED);
  if (!Object.keys(patch).length) return { ...plan, action: 'none' };
  return {
    ...plan,
    action: 'update',
    update: {
      endpoint: 'updateSellerListingByExternalId',
      method: 'PATCH',
      path: `/externalsellerlistings/${encodeURIComponent(allocationId)}`,
      body: patch,
    },
  };
}

export function stubHubDelist(allocationId: string): DelistPlan {
  return {
    action: 'delist',
    endpoint: 'deleteSellerListingByExternalId',
    method: 'DELETE',
    path: `/externalsellerlistings/${encodeURIComponent(allocationId)}`,
  };
}
