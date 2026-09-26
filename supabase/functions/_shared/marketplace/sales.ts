// Marketplace sale -> the exos_record_marketplace_order payload, and the
// delivery plan once Exos has minted the tickets (mig 20260926192000).
// Pure: used by exos-marketplace-sales (Deno) and tested with vitest.

import type { MarketplaceChannel, MarketplaceSale, PlannedRequest } from './channel.ts';
import { exosClaimUrl } from './stubhub/fulfilment.ts';

/** The jsonb exos_record_marketplace_order takes. */
export function recordPayload(sale: MarketplaceSale, raw?: unknown): Record<string, unknown> {
  const p: Record<string, unknown> = {
    channel: sale.channel,
    external_order_id: sale.externalOrderId,
    external_event_id: sale.externalEventId,
    external_listing_id: sale.externalListingId,
    quantity: sale.quantity,
    sale_status: sale.status,
    buyer_email: sale.buyerEmail,
    currency: sale.proceeds?.currency ?? null,
  };
  if (sale.proceeds && Number.isFinite(sale.proceeds.amount) && sale.proceeds.amount >= 0) {
    p.proceeds = sale.proceeds.amount.toFixed(2);
  }
  if (sale.confirmBy) p.confirm_by = sale.confirmBy;
  if (sale.shipBy) p.ship_by = sale.shipBy;
  if (sale.createdAt) p.sold_at = sale.createdAt;
  if (raw !== undefined) p.raw = raw;
  return p;
}

export type DeliveryPlan =
  | { kind: 'planned'; request: PlannedRequest; claim_urls: string[] }
  | { kind: 'manual'; reason: string; claim_urls: string[] };

/**
 * What delivers the tickets: the channel's URL-delivery call (dry-run), or a
 * note for a human when the channel can't take URLs or the app URL is unset.
 */
export function planDelivery(
  channel: MarketplaceChannel,
  order: { external_order_id: string; quantity: number; transfer_ids: string[] },
  appBase: string | undefined,
): DeliveryPlan {
  if (!appBase) return { kind: 'manual', reason: 'EXOS_APP_BASE_URL is not set, so there are no claim links', claim_urls: [] };
  const urls = order.transfer_ids.map((t) => exosClaimUrl(appBase, t));
  if (!channel.capabilities.fulfilByUrls || !channel.planFulfilByUrls) {
    return { kind: 'manual', reason: `${channel.label} can't take ticket links through its API: send them by hand`, claim_urls: urls };
  }
  const sale = { externalOrderId: order.external_order_id, quantity: order.quantity } as MarketplaceSale;
  return { kind: 'planned', request: channel.planFulfilByUrls(sale, urls), claim_urls: urls };
}
