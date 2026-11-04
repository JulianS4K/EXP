// The dashboard's Orders page (mig 20261102140000): pure parts. Row parsing,
// the table's sort / filter / paging state, who may do what, and how the edit
// history reads. The calls are in ./orderDeskApi.ts. The request parsing and
// the guest-list preview are shared with exos-api (re-exported below).
//
// Roles (the RPCs re-check every one):
//   owner / manager   read orders, edit buyers and attendees, resend
//                     receipts, check orders out, read the edit history
//   finance           read orders (no actions)
//   owner             also the receipt rules (another address; resends an hour)

export * from '../../supabase/functions/_shared/orderEdits.ts';
export {
  parsePastedLine, parsePastedNames, previewInput, PreviewError, type PreviewInput, type PreviewRow, type SkippedLine,
} from '../../supabase/functions/_shared/guestPreview.ts';

export type OrderStatus = 'fulfilled' | 'partially_refunded' | 'refunded' | 'failed';
export const ORDER_STATUSES: readonly OrderStatus[] = ['fulfilled', 'partially_refunded', 'refunded', 'failed'];
export const STATUS_LABEL: Record<OrderStatus, string> = {
  fulfilled: 'Paid', partially_refunded: 'Part refunded', refunded: 'Refunded', failed: 'Failed',
};

export type OrderSort = 'created_at' | 'amount_cents' | 'email' | 'event' | 'status';
export const ORDER_SORTS: readonly { id: OrderSort; label: string }[] = [
  { id: 'created_at', label: 'Date' }, { id: 'event', label: 'Event' }, { id: 'email', label: 'Buyer' },
  { id: 'amount_cents', label: 'Amount' }, { id: 'status', label: 'Status' },
];

export interface OrderRow {
  sessionId: string;
  eventId: string;
  eventName: string;
  status: OrderStatus | string;
  quantity: number;
  amountCents: number;
  currency: string;
  email: string | null;
  firstName: string | null;
  lastName: string | null;
  phone: string | null;
  notes: string | null;
  createdAt: Date | null;
  receiptsSent: number;
  lastEditAt: Date | null;
}

const int = (v: unknown) => Math.max(0, Math.trunc(Number(v) || 0));
const date = (v: unknown) => (typeof v === 'string' && v ? new Date(v) : null);
const strOrNull = (v: unknown) => (typeof v === 'string' && v !== '' ? v : null);

export function parseOrderRow(r: any): OrderRow {
  return {
    sessionId: String(r?.session_id ?? ''),
    eventId: String(r?.event_id ?? ''),
    eventName: String(r?.event_name ?? ''),
    status: String(r?.status ?? ''),
    quantity: int(r?.quantity),
    amountCents: int(r?.amount_cents),
    currency: String(r?.currency ?? 'usd'),
    email: strOrNull(r?.buyer_email ?? r?.email),
    firstName: strOrNull(r?.first_name),
    lastName: strOrNull(r?.last_name),
    phone: strOrNull(r?.phone ?? r?.phone_number),
    notes: strOrNull(r?.notes),
    createdAt: date(r?.created_at),
    receiptsSent: int(r?.receipts_sent),
    lastEditAt: date(r?.last_edit_at),
  };
}

/** The buyer as the table shows them: their name, else their email. */
export function buyerLabel(o: Pick<OrderRow, 'firstName' | 'lastName' | 'email'>): string {
  const n = [o.firstName, o.lastName].filter(Boolean).join(' ').trim();
  return n || o.email || 'Guest';
}

export function statusLabel(s: string): string {
  return (STATUS_LABEL as Record<string, string>)[s] ?? s;
}

/** Money in the order's currency, e.g. "$60.00" / "EUR 12.50". */
export function formatOrderAmount(cents: number, currency: string): string {
  const v = (cents / 100).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return currency.toLowerCase() === 'usd' ? `$${v}` : `${currency.toUpperCase()} ${v}`;
}

// ── Table state ──────────────────────────────────────────────────────────────

export interface OrderTableState {
  search: string;
  status: OrderStatus | '';
  eventId: string;
  sort: OrderSort;
  desc: boolean;
  page: number;
  perPage: number;
}

export const DEFAULT_ORDER_TABLE: OrderTableState = {
  search: '', status: '', eventId: '', sort: 'created_at', desc: true, page: 1, perPage: 25,
};

/** Clicking a column header: the same column flips direction, another starts at its natural order. */
export function toggleSort(s: OrderTableState, col: OrderSort): OrderTableState {
  if (s.sort === col) return { ...s, desc: !s.desc, page: 1 };
  return { ...s, sort: col, desc: col === 'created_at' || col === 'amount_cents', page: 1 };
}

/** Any filter change goes back to page 1. */
export function withFilter(s: OrderTableState, patch: Partial<Pick<OrderTableState, 'search' | 'status' | 'eventId'>>): OrderTableState {
  return { ...s, ...patch, page: 1 };
}

export function pageCount(total: number, perPage: number): number {
  return Math.max(1, Math.ceil(Math.max(0, total) / Math.max(1, perPage)));
}

/** "26-50 of 112" */
export function pageRangeLabel(page: number, perPage: number, total: number): string {
  if (total <= 0) return '0 of 0';
  const from = (page - 1) * perPage + 1;
  return `${Math.min(from, total)}-${Math.min(page * perPage, total)} of ${total}`;
}

/** The RPC's arguments for a table state. */
export function orderQuery(orgId: string, s: OrderTableState) {
  const search = s.search.trim();
  return {
    p_org_id: orgId, p_search: search ? search.slice(0, 100) : null, p_status: s.status || null,
    p_event_id: s.eventId || null, p_sort: s.sort, p_desc: s.desc, p_limit: s.perPage, p_offset: (s.page - 1) * s.perPage,
  };
}

// ── Roles ───────────────────────────────────────────────────────────────────────

export interface OrderPermissions {
  read: boolean;
  edit: boolean;
  resend: boolean;
  checkOut: boolean;
  history: boolean;
  receiptRules: boolean;
}

export function orderPermissions(role: string | null | undefined, isAdmin = false): OrderPermissions {
  const r = isAdmin ? 'owner' : role ?? null;
  const staff = r === 'owner' || r === 'manager';
  return {
    read: staff || r === 'finance',
    edit: staff, resend: staff, checkOut: staff, history: staff,
    receiptRules: r === 'owner',
  };
}

/** The row actions a role sees for an order (writes hidden from roles that can't). */
export function orderActions(o: Pick<OrderRow, 'status'>, perm: OrderPermissions): Array<'edit' | 'receipt' | 'check_out' | 'history'> {
  const out: Array<'edit' | 'receipt' | 'check_out' | 'history'> = [];
  const placed = o.status !== 'failed';
  if (perm.edit && placed) out.push('edit');
  if (perm.resend && placed) out.push('receipt');
  if (perm.checkOut && (o.status === 'fulfilled' || o.status === 'partially_refunded')) out.push('check_out');
  if (perm.history) out.push('history');
  return out;
}

// ── Edit history ───────────────────────────────────────────────────────────────

export interface OrderEditRow {
  id: string;
  sessionId: string;
  ticketId: string | null;
  action: 'order.update' | 'order.receipt' | 'order.check_out' | 'ticket.update' | string;
  actorEmail: string | null;
  viaApi: boolean;
  changes: Record<string, any>;
  createdAt: Date | null;
}

export function parseOrderEdit(r: any): OrderEditRow {
  return {
    id: String(r?.id ?? ''),
    sessionId: String(r?.session_id ?? ''),
    ticketId: strOrNull(r?.ticket_id),
    action: String(r?.action ?? ''),
    actorEmail: strOrNull(r?.actor_email),
    viaApi: r?.via_api === true,
    changes: r?.changes && typeof r.changes === 'object' ? r.changes : {},
    createdAt: date(r?.created_at),
  };
}

const FIELD_LABEL: Record<string, string> = {
  first_name: 'first name', last_name: 'last name', email: 'email', phone: 'phone', notes: 'notes', attendee_name: 'attendee',
};

/** One line per history row: "email: a@x.com → b@x.com", "Receipt sent to b@x.com", ... */
export function describeEdit(e: Pick<OrderEditRow, 'action' | 'changes'>): string {
  const c = e.changes;
  if (e.action === 'order.receipt') return `Receipt sent to ${c.to ?? 'the buyer'}${c.override ? ' (another address)' : ''}`;
  if (e.action === 'order.check_out') return `Checked out ${int(c.checked_out)} ticket${int(c.checked_out) === 1 ? '' : 's'}`;
  const parts = Object.entries(c)
    .filter(([, v]) => v && typeof v === 'object' && 'to' in (v as object))
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]: [string, any]) => `${FIELD_LABEL[k] ?? k}: ${v.from ?? '(none)'} → ${v.to ?? '(none)'}`);
  return parts.join('; ') || (e.action === 'ticket.update' ? 'Ticket edited' : 'Order edited');
}

/** The check-out answer as a toast. */
export function checkOutSummary(r: { checked_out?: number; results?: Array<{ reason?: string }> }): string {
  const n = int(r.checked_out);
  const results = Array.isArray(r.results) ? r.results : [];
  const notAllowed = results.filter((x) => x.reason === 'exit-not-allowed').length;
  if (n > 0) return `Checked out ${n} ticket${n === 1 ? '' : 's'}.`;
  if (notAllowed > 0) return 'Nothing to check out: these tickets came in on a list without re-entry.';
  return 'Nothing to check out: no ticket on this order is inside.';
}

// ── Guest-list preview table ──────────────────────────────────────────────────

export type PreviewStatus = 'ready' | 'duplicate' | 'invalid' | 'too_many_plus_ones';

export interface PreviewResultRow {
  row: number;
  status: PreviewStatus | string;
  reason?: string;
  name?: string;
  email?: string;
  plus_ones?: number;
  tickets?: number;
  existing_list_name?: string;
  warnings?: string[];
}

/** The preview's rows for one status tab ('' = all), in file order. */
export function filterPreviewRows(rows: PreviewResultRow[], status: PreviewStatus | ''): PreviewResultRow[] {
  return (status ? rows.filter((r) => r.status === status) : [...rows]).sort((a, b) => a.row - b.row);
}

/** What a preview row's status column says. */
export function previewStatusText(r: PreviewResultRow): string {
  if (r.status === 'duplicate') return r.reason === 'in_file' ? 'Repeated in this import' : `Already on ${r.existing_list_name ?? 'a list'}`;
  if (r.status === 'invalid') return r.reason ? `Skipped: ${r.reason}` : 'Skipped';
  if (r.status === 'too_many_plus_ones') return `Too many plus-ones (${r.reason ?? 'over the limit'})`;
  return r.warnings?.includes('invalid_email') ? 'Ready (email dropped: not valid)' : 'Ready';
}
