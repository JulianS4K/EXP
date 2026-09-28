// Ticket Evolution API v9 shapes, as far as the pages the operator supplied
// (2026-09-28; docs/marketplace/tevo/README.md) show them. Only the fields
// Exos uses are typed; everything else passes through untyped.

/** Who bought: TEvo itself (Office 6) or a Client of a TEvo-powered seller site. */
export interface TevoBuyer {
  type?: 'Office' | 'Client' | string;
  id?: number;
  name?: string;
  email_address?: string | { address?: string };
  [key: string]: unknown;
}

/** Riskified result on sales to a Client: null = not screened, pending = wait. */
export type TevoFraudCheckStatus = null | 'pending' | 'approved' | string;

export interface TevoTicketGroup {
  id?: number;
  section?: string;
  row?: string;
  /** The seller's own id for the group (Exos: exos_tevo_remote_ids). */
  remote_id?: number | string;
  /** Set by Exos from remote_id (orders.ts annotateTevoOrder), never by TEvo. */
  exos_listing_id?: string;
  [key: string]: unknown;
}

export interface TevoOrderItem {
  /** The item's id (add_etickets addresses it). */
  id?: number;
  /** order_item_id (deliver_etickets addresses this one). */
  order_item_id?: number;
  quantity?: number;
  price?: number | string;
  eticket_delivery?: boolean;
  ticket_group?: TevoTicketGroup;
  [key: string]: unknown;
}

export type TevoShipmentType = 'TBD' | 'TMMobile' | 'TMMobileLink' | 'FlashSeats' | 'Eticket' | 'FedEx' | 'LocalPickup' | string;

export interface TevoShipment {
  id: number;
  url?: string;
  type?: TevoShipmentType;
  state?: string;
  ship_to_name?: string;
  email_address?: { address?: string } | string;
  tm_mobile_link?: string;
  [key: string]: unknown;
}

export interface TevoOrder {
  id: number;
  /** Display id, e.g. "61449-190823". */
  oid?: string;
  state?: string;
  buyer?: TevoBuyer;
  fraud_check_status?: TevoFraudCheckStatus;
  items?: TevoOrderItem[];
  shipments?: TevoShipment[];
  total?: number | string;
  created_at?: string;
  event?: { id?: number; name?: string; occurs_at?: string };
  [key: string]: unknown;
}

/** Shipments / Update body: how the tickets will be delivered. */
export interface TevoShipmentUpdate {
  mobile_transfer_type: 'TMMobileLink' | 'TMMobile';
  /** One of TEvo's Shipments / Complete transfer_source values (list not supplied yet). */
  transfer_source?: string;
}

/** Shipments / Complete body. */
export interface TevoShipmentComplete {
  tm_mobile_link?: string;
  transfer_source?: string;
}

export interface TevoAcceptBody {
  reviewer_id: number;
  seats?: number[];
}

// ── Inventory (Inventory / Create, Update, Delete) ──────────────────────

export type TevoTicketFormat = 'Eticket' | 'Flash_seats' | 'Guest_list' | 'Paperless' | 'Physical' | 'TM_mobile';
export type TevoSplitType = 'DEFAULT' | 'ANY' | 'NEVERLEAVEONE' | 'NONE' | 'CUSTOM';

export interface TevoInventorySeat {
  /** Unique within the group. */
  seat: number;
  barcode?: string;
  primary_ticket_id?: string;
  verification_id?: string;
}

export interface TevoInventoryTicket {
  format: TevoTicketFormat;
  /** At most 1,000,000. */
  price: number;
  /** At least 1; equals seats.length when seats are sent. */
  quantity: number;
  /** Ours: a positive integer, unique per office (mig 20260928080000). */
  remote_id: number;
  row: string;
  section: string;
  type: 'EVENT' | 'PARKING';
  seats?: TevoInventorySeat[];
  split_type?: TevoSplitType;
  split_override?: number[];
  in_hand?: boolean;
  /** YYYY-MM-DD; required when in_hand is false. */
  in_hand_on?: string;
  face_value?: number;
  cost?: number;
  external_notes?: string;
  internal_notes?: string;
  instant_delivery?: boolean;
  wheelchair_accessible?: boolean;
  [key: string]: unknown;
}

export interface TevoInventory {
  event: { id?: number; name?: string; occurs_at_date?: string; occurs_at_time?: string; tbd?: boolean };
  office: { id?: number; name?: string };
  ticket: TevoInventoryTicket;
  venue: { id?: number; name: string };
}

/** Inventory / Create body. */
export interface TevoInventoryBody {
  inventory: TevoInventory;
}

/** Inventory / Update body: the changed fields only. */
export interface TevoInventoryPatch {
  inventory: { ticket?: Partial<Omit<TevoInventoryTicket, 'remote_id'>> };
}
