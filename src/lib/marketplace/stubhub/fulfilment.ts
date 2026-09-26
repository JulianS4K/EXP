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
// For Exos primary inventory the natural route is mobile transfer: the
// ticket already lives in Exos, so we reissue it to the buyer and report
// the transfer. "Exos" isn't one of StubHub's providers yet; that's a
// partner conversation, flagged in docs/marketplace/stubhub/README.md.

import type { Sale, Seating } from './types';

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
  /** Item shape collapsed in the docs; confirm against the sandbox. */
  eticket_urls?: unknown[];
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
