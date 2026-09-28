// Every Ticket Evolution (TEvo) API v9 endpoint Exos knows about
// (docs/marketplace/tevo/README.md), tagged by what it does to TEvo.
//
//   read       changes nothing.
//   write      changes TEvo state. Built, dry-run; sending one needs an
//              operator WriteAuthorization (Hard Rule #2).
//   forbidden  never sent, even with an authorization.
//
// Exos is a SELLER on TEvo: it lists its allocations as inventory (ticket
// groups, one per Exos listing, addressed by id), orders for them arrive, it
// accepts them and delivers mobile transfers. Forbidden:
//   * createOrder: a purchase (substitutions are purchases too). Exos never buys.
//   * etickets (add / finalize / remove / deliver): static PDF or QR files.
//     An Exos barcode rotates and is only valid once claimed, so a file
//     would never scan; delivery is the claim link (mobile transfer).
//   * airbills and local pickup: Exos has no physical tickets.
//   * bulk inventory update / delete: one call changes up to 1,000 ticket
//     groups by TEvo id, broker ones included if an id is wrong. Exos
//     changes its listings one at a time, each checked as its own.
//   * payments (create / apply / cancel / refund): they move money on an
//     order, and the office's orders include Terminal-2's broker ones.
//     TEvo pays Exos (EvoPay); Exos only reads what was paid. Note that
//     apply and cancel are GETs that change state: access is decided by
//     this tag, never by the HTTP method.
// The TEvo office can carry Terminal-2 broker inventory and orders; the
// writer only touches Exos listings and orders for them (writer.ts).

export type Access = 'read' | 'write' | 'forbidden';
export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface Endpoint {
  method: HttpMethod;
  path: string;
  access: Access;
}

const e = <A extends Access>(method: HttpMethod, path: string, access: A) => ({ method, path, access });

export const TEVO_HOSTS = {
  production: 'https://api.ticketevolution.com',
  sandbox: 'https://api.sandbox.ticketevolution.com',
} as const;
export type TevoEnvironment = keyof typeof TEVO_HOSTS;

export const TEVO_ENDPOINTS = {
  // Orders (seller side)
  listOrders: e('GET', '/v9/orders', 'read'),
  showOrder: e('GET', '/v9/orders/{order_id}', 'read'),
  /** Commits us to deliver: body {reviewer_id, seats?}. */
  acceptOrder: e('POST', '/v9/orders/{order_id}/accept', 'write'),

  // Shipments (mobile transfer)
  showShipment: e('GET', '/v9/shipments/{shipment_id}', 'read'),
  /** Sets the delivery type on a TBD shipment; TEvo answers with a new shipment. */
  updateShipment: e('PUT', '/v9/shipments/{shipment_id}', 'write'),
  /** Hands over the transfer link and marks the shipment (and order) delivered. */
  completeShipment: e('PUT', '/v9/shipments/{shipment_id}/complete', 'write'),

  // Inventory (seller side): one ticket group per Exos listing.
  /** Body {inventory: {event, office, ticket, venue}}; 201 with inventory.id. */
  createInventory: e('POST', '/v9/inventory', 'write'),
  /** Changed fields only; a new quantity recreates the group's tickets. */
  updateInventory: e('PATCH', '/v9/inventory/{inventory_id}', 'write'),
  /** 204. */
  deleteInventory: e('DELETE', '/v9/inventory/{inventory_id}', 'write'),

  // Payments: how TEvo pays Exos for an order (read for the payout ledger).
  /** ?order_id= (required): the order's payments. */
  listPayments: e('GET', '/v9/payments', 'read'),
  showPayment: e('GET', '/v9/payments/{payment_id}', 'read'),
  /** The office's payments across orders; TEvo documents it for its POS only. */
  paymentsStatus: e('GET', '/v9/payments/status', 'read'),

  // Buyer-side search (read-only; not used for selling).
  listListings: e('GET', '/v9/listings', 'read'),

  // Never sent by Exos.
  createOrder: e('POST', '/v9/orders', 'forbidden'),
  addEtickets: e('POST', '/v9/orders/{order_id}/items/{item_id}/add_etickets', 'forbidden'),
  finalizeEtickets: e('POST', '/v9/orders/{order_id}/items/{item_id}/finalize_etickets', 'forbidden'),
  removeEtickets: e('POST', '/v9/orders/{order_id}/items/{item_id}/remove_etickets', 'forbidden'),
  deliverEtickets: e('POST', '/v9/orders/{order_id}/deliver_etickets', 'forbidden'),
  bulkUpdateInventory: e('PATCH', '/v9/inventory', 'forbidden'),
  bulkDeleteInventory: e('DELETE', '/v9/inventory', 'forbidden'),
  createPayment: e('POST', '/v9/payments', 'forbidden'),
  /** A GET that completes a pending payment. */
  applyPayment: e('GET', '/v9/payments/{payment_id}/apply', 'forbidden'),
  /** A GET that cancels a pending payment. */
  cancelPayment: e('GET', '/v9/payments/{payment_id}/cancel', 'forbidden'),
  refundPayment: e('POST', '/v9/payments/{payment_id}/refund', 'forbidden'),
} as const satisfies Record<string, Endpoint>;

export type EndpointName = keyof typeof TEVO_ENDPOINTS;

/** Fills `{name}` segments, URI-encoding each value. Throws on a missing one. */
export function buildPath(template: string, params: Record<string, string | number> = {}): string {
  return template.replace(/\{(\w+)\}/g, (_, key: string) => {
    const v = params[key];
    if (v === undefined || v === '') throw new Error(`tevo: missing path param "${key}" for ${template}`);
    return encodeURIComponent(String(v));
  });
}
