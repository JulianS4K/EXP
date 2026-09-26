// Table packages (mig 20260926050000) — Supabase wrappers. Pure logic lives
// in ./tables. Tier table fields are plain columns on exos_ticket_tiers
// (org staff write them through the tier RLS policy); bookings are read and
// changed only through SECURITY DEFINER RPCs.

import { supabase } from './supabase';
import { tableDraftToRow, type TableFacts, type TableTierDraft, type TableTierRow } from './tables';

export interface PublicTableTier extends TableFacts {
  tierId: string;
  tablesLeft: number | null;
}

export interface EventTable {
  bookingId: string;
  tierId: string | null;
  tierName: string | null;
  sectionLabel: string | null;
  partySize: number;
  minSpendCents: number | null;
  label: string | null;
  status: 'active' | 'cancelled';
  hostEmail: string | null;
  hostName: string | null;
  tickets: number;
  checkedIn: number;
  createdAt: string;
}

/** Staff read of every tier's table fields for one event, keyed by tier id. */
export async function getTierTableRows(eventId: string): Promise<Record<string, TableTierRow>> {
  const { data, error } = await supabase
    .from('exos_ticket_tiers')
    .select('id, kind, party_size, min_spend_cents, section_label')
    .eq('event_id', eventId);
  if (error) throw error;
  const out: Record<string, TableTierRow> = {};
  for (const r of data ?? []) {
    out[(r as any).id] = {
      kind: (r as any).kind === 'table' ? 'table' : 'standard',
      party_size: (r as any).party_size ?? null,
      min_spend_cents: (r as any).min_spend_cents ?? null,
      section_label: (r as any).section_label ?? null,
    };
  }
  return out;
}

/** Write one tier's table fields. Kind / party size lock once the tier has sales. */
export async function saveTierTableConfig(tierId: string, d: TableTierDraft): Promise<void> {
  const { error } = await supabase.from('exos_ticket_tiers').update(tableDraftToRow(d)).eq('id', tierId);
  if (error) throw error;
}

/**
 * After createEvent inserted the tiers (sort_order = form index), mark the
 * table tiers. Only rows that are tables are written.
 */
export async function applyTableConfigsBySortOrder(
  eventId: string,
  drafts: { sortOrder: number; draft: TableTierDraft }[],
): Promise<void> {
  for (const { sortOrder, draft } of drafts) {
    if (!draft.isTable) continue;
    const { error } = await supabase
      .from('exos_ticket_tiers')
      .update(tableDraftToRow(draft))
      .eq('event_id', eventId)
      .eq('sort_order', sortOrder);
    if (error) throw error;
  }
}

/** Buyer side: the table facts of an event's public tiers (anon-callable). */
export async function getPublicTableTiers(eventId: string): Promise<PublicTableTier[]> {
  const { data, error } = await supabase.rpc('exos_public_table_tiers', { p_event_id: eventId });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    tierId: String(r.tier_id),
    partySize: Number(r.party_size) || 1,
    minSpendCents: r.min_spend_cents != null ? Number(r.min_spend_cents) : null,
    sectionLabel: r.section_label ?? null,
    tablesLeft: r.tables_left != null ? Number(r.tables_left) : null,
  }));
}

/** Organizer list of sold tables (owner / manager / finance). */
export async function listEventTables(eventId: string): Promise<EventTable[]> {
  const { data, error } = await supabase.rpc('exos_event_tables', { p_event_id: eventId });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    bookingId: String(r.booking_id),
    tierId: r.tier_id ?? null,
    tierName: r.tier_name ?? null,
    sectionLabel: r.section_label ?? null,
    partySize: Number(r.party_size) || 1,
    minSpendCents: r.min_spend_cents != null ? Number(r.min_spend_cents) : null,
    label: r.label ?? null,
    status: r.status === 'cancelled' ? 'cancelled' : 'active',
    hostEmail: r.host_email ?? null,
    hostName: r.host_name ?? null,
    tickets: Number(r.tickets) || 0,
    checkedIn: Number(r.checked_in) || 0,
    createdAt: String(r.created_at ?? ''),
  }));
}

/** Give a sold table its number / name (owner / manager). null clears it. */
export async function assignTable(bookingId: string, label: string | null): Promise<void> {
  const { error } = await supabase.rpc('exos_assign_table', { p_booking_id: bookingId, p_label: label ?? '' });
  if (error) throw error;
}

/** Cancel a free table as a whole (owner / manager). Returns tickets voided. */
export async function cancelTableBooking(bookingId: string): Promise<number> {
  const { data, error } = await supabase.rpc('exos_cancel_table_booking', { p_booking_id: bookingId });
  if (error) throw error;
  return Number(data) || 0;
}
