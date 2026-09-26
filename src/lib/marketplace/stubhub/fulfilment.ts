// Sale fulfilment, step 2 of the write foundation: the PATCH /sales/{id}
// bodies for each way a sale gets fulfilled, plus the deadline logic the
// reconcile loop needs. Pure: nothing here talks to the network.
//
// A StubHub sale must be confirmed by `confirm_by` and delivered by
// `ship_by`. The delivery routes in the docs:
//   • mobile transfer: confirm + transfer_confirmation_number + mobile_provider
//   • e-ticket PDF:    upload (POST /sales/{id}/eticketuploads), then PATCH
//                      eticket_ids with the pages to keep
//   • e-ticket URL:    PATCH eticket_urls
//   • reject:          DELETE /sales/{id} (report a problem; no body)
//
// Exos uses the e-ticket URL route (decided 2026-09-26): each ticket sold
// on StubHub becomes an Exos transfer addressed to the buyer's email, and
// StubHub hands the buyer one claim link per ticket (/claim/{transferId}).
// Mobile transfer would need "Exos" on StubHub's provider list, which it
// isn't.

import type { Sale, Seating, TicketHolder } from './types';

/** `mobile_provider` values, verbatim from the Sales reference. */
export const MOBILE_TRANSFER_PROVIDERS = [
  'StubHub', 'Viagogo', 'Ticketmaster', 'AXS', 'SeatGeek', 'Ticketmaster Account Manager',
  'MLB Ballpark', 'MPV', 'Paciolan', 'Tickets.com', 'Tickets.com RDP', 'Vivenu', 'Ticketmaster CA',
  'Eventbrite', 'Livenation', 'Broadway', 'Telecharge', 'Ticketon', 'Seetickets', 'Etix', 'Tixr',
  'Festicket', 'Insomniac', 'DiceImport', 'MGMResorts', 'Tickeri', 'SmithCenterImport', 'Stubwire',
  'Computicket',
] as const;

export type MobileTransferProvider = (typeof MOBILE_TRANSFER_PROVIDERS)[number];

/** Body of PATCH /sales/{saleId}. */
export interface UpdateSaleRequest {
  confirmed?: boolean;
  eticket_ids?: number[];
  transfer_confirmation_number?: string;
  eticket_urls?: ETicketUrlItem[];
  change_paper_ticket_to_eticket?: boolean;
  confirm_same_day_shipment?: boolean;
  in_hand_at?: string;
  eticket_type?: string;
  tracking_number?: string;
  seating?: Seating;
  barcodes?: unknown[];
  mobile_provider?: MobileTransferProvider;
}

export class FulfilmentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FulfilmentError';
  }
}

export function confirmSaleRequest(): UpdateSaleRequest {
  return { confirmed: true };
}

export function mobileTransferRequest(provider: MobileTransferProvider, confirmationNumber: string): UpdateSaleRequest {
  if (!(MOBILE_TRANSFER_PROVIDERS as readonly string[]).includes(provider)) {
    throw new FulfilmentError(`"${provider}" is not a documented StubHub mobile_provider`);
  }
  if (!confirmationNumber.trim()) throw new FulfilmentError('transfer confirmation number is required');
  return { confirmed: true, mobile_provider: provider, transfer_confirmation_number: confirmationNumber.trim() };
}

/** After POST /sales/{id}/eticketuploads: attach the e-ticket pages to the sale. */
export function attachETicketsRequest(eticketIds: number[]): UpdateSaleRequest {
  if (!eticketIds.length) throw new FulfilmentError('at least one e-ticket id is required');
  if (new Set(eticketIds).size !== eticketIds.length) throw new FulfilmentError('duplicate e-ticket ids');
  return { confirmed: true, eticket_ids: eticketIds };
}

// ── E-ticket URL route (Exos default) ────────────────────────────────

/**
 * One `ETicketUrlRequest`. The printed docs collapse this object, so its
 * field name is UNCONFIRMED. `{ url }` is the working assumption; when it's
 * checked against the sandbox, fix it here (and in toETicketUrlItem) only.
 */
export interface ETicketUrlItem {
  url: string;
}

export function toETicketUrlItem(url: string): ETicketUrlItem {
  return { url };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The buyer-facing claim link for one Exos transfer. `appOrigin` is the
 * public SPA origin (https only; claim links carry ticket ownership).
 */
export function exosClaimUrl(appOrigin: string, transferId: string): string {
  let origin: URL;
  try {
    origin = new URL(appOrigin);
  } catch {
    throw new FulfilmentError(`app origin "${appOrigin}" is not a URL`);
  }
  if (origin.protocol !== 'https:') throw new FulfilmentError('claim links must use https');
  if (!UUID_RE.test(transferId)) throw new FulfilmentError(`transfer id "${transferId}" is not a uuid`);
  return `${origin.origin}/claim/${transferId.toLowerCase()}`;
}

/**
 * Confirm the sale and hand StubHub one URL per ticket. `ticketCount` is
 * the sale's `number_of_tickets`; a mismatch means we'd under- or
 * over-deliver, so it's refused.
 */
export function eticketUrlsRequest(urls: string[], ticketCount: number): UpdateSaleRequest {
  if (!urls.length) throw new FulfilmentError('at least one e-ticket url is required');
  if (urls.length !== ticketCount) {
    throw new FulfilmentError(`sale has ${ticketCount} ticket(s) but ${urls.length} url(s) were given`);
  }
  if (new Set(urls).size !== urls.length) throw new FulfilmentError('duplicate e-ticket urls');
  for (const u of urls) {
    let parsed: URL;
    try {
      parsed = new URL(u);
    } catch {
      throw new FulfilmentError(`"${u}" is not a URL`);
    }
    if (parsed.protocol !== 'https:') throw new FulfilmentError(`"${u}" is not https`);
  }
  return { confirmed: true, eticket_urls: urls.map(toETicketUrlItem) };
}

/**
 * The email Exos should address the transfers to, from
 * GET /sales/{id}/ticketholders. The response shape (single object, array,
 * or paged list) isn't pinned down in the docs, so accept all three. Returns
 * null when there's no usable address: that sale can't go down the URL
 * route automatically and needs a human.
 */
export function buyerEmail(holders: unknown): string | null {
  let list: TicketHolder[] = [];
  if (Array.isArray(holders)) list = holders as TicketHolder[];
  else if (holders && typeof holders === 'object') {
    const items = (holders as { _embedded?: { items?: unknown } })._embedded?.items;
    list = Array.isArray(items) ? (items as TicketHolder[]) : [holders as TicketHolder];
  }
  for (const h of list) {
    const e = h?.email_address?.trim().toLowerCase();
    if (e && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) return e;
  }
  return null;
}

// ── Deadlines ────────────────────────────────────────────────────────

export type SaleAction = 'confirm' | 'deliver' | 'none';

export interface SaleDeadline {
  action: SaleAction;
  due: Date | null;
  overdue: boolean;
  /** Milliseconds left; negative when overdue; null when there's no deadline. */
  remainingMs: number | null;
}

/**
 * What a sale needs from us next and by when. `confirmed` comes from our own
 * record (StubHub's `status` strings aren't enumerated in the docs, so we
 * don't parse them).
 */
export function saleDeadline(
  sale: Pick<Sale, 'confirm_by' | 'ship_by'>,
  ours: { confirmed: boolean; delivered: boolean },
  now: Date = new Date(),
): SaleDeadline {
  const pick = (action: SaleAction, iso: string | null | undefined): SaleDeadline => {
    const due = iso ? new Date(iso) : null;
    const remainingMs = due && !Number.isNaN(due.getTime()) ? due.getTime() - now.getTime() : null;
    return { action, due: remainingMs == null ? null : due, overdue: remainingMs != null && remainingMs < 0, remainingMs };
  };
  if (!ours.confirmed) return pick('confirm', sale.confirm_by);
  if (!ours.delivered) return pick('deliver', sale.ship_by);
  return { action: 'none', due: null, overdue: false, remainingMs: null };
}
