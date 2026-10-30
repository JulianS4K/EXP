// Sales counts from other platforms (mig 20261030120000): reads and writes for
// the event report and the dashboard. The CSV mapping and sums are shared with
// exos-api (supabase/functions/_shared/salesCounts.ts); the parser is the one
// Exos Door uses (supabase/functions/_shared/csvParse.ts).
//
// Owners, managers and finance read and write (RLS + the RPCs re-check);
// everyone else reads nothing and these calls fail or return [].

import { supabase } from './supabase';
import type { SalesCountRow, SalesTier } from '../../supabase/functions/_shared/salesCounts.ts';

export * from '../../supabase/functions/_shared/salesCounts.ts';
export { parseCsv } from '../../supabase/functions/_shared/csvParse.ts';

const COLS = 'id, event_id, kind, platform, label, sold, gross_cents, currency, capacity, tiers, note, file_name, row_count, updated_at';

/** The event's entries, newest first; null when unreadable (no role, or the table isn't there yet). */
export async function listSalesCounts(eventId: string): Promise<SalesCountRow[] | null> {
  const { data, error } = await supabase
    .from('exos_sales_counts')
    .select(COLS)
    .eq('event_id', eventId)
    .order('updated_at', { ascending: false });
  if (error) {
    console.warn('sales counts unavailable (non-fatal):', error.message);
    return null;
  }
  return (data as unknown as SalesCountRow[] | null) ?? [];
}

/** Tickets sold elsewhere per event, for a set of the org's events (dashboard). */
export async function soldElsewhereByEvent(eventIds: string[]): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  if (eventIds.length === 0) return out;
  for (let i = 0; i < eventIds.length; i += 200) {
    const { data, error } = await supabase
      .from('exos_sales_count_totals')
      .select('event_id, sold')
      .in('event_id', eventIds.slice(i, i + 200));
    if (error) return out;
    for (const r of (data ?? []) as { event_id: string; sold: number | string }[]) {
      out.set(r.event_id, (out.get(r.event_id) ?? 0) + Number(r.sold || 0));
    }
  }
  return out;
}

export interface WriteResult {
  id: string;
  status: 'created' | 'updated' | 'unchanged';
  sold: number;
  gross_cents: number;
  currency: string;
}

export async function setManualCount(eventId: string, input: {
  label: string; sold: number; grossCents: number; currency: string; capacity?: number | null; note?: string | null;
}): Promise<WriteResult> {
  const { data, error } = await supabase.rpc('exos_set_sales_count', {
    p_event_id: eventId,
    p_label: input.label,
    p_sold: input.sold,
    p_gross_cents: input.grossCents,
    p_currency: input.currency,
    p_capacity: input.capacity ?? null,
    p_note: input.note ?? null,
  });
  if (error) throw new Error(cleanError(error.message));
  return data as WriteResult;
}

export async function importSalesCounts(eventId: string, input: {
  platform: string; currency: string; tiers: SalesTier[]; sold: number; grossCents: number;
  capacity: number | null; fileName: string | null; rowCount: number;
}): Promise<WriteResult> {
  const { data, error } = await supabase.rpc('exos_import_sales_counts', {
    p_event_id: eventId,
    p_platform: input.platform,
    p_currency: input.currency,
    p_tiers: input.tiers,
    p_sold: input.sold,
    p_gross_cents: input.grossCents,
    p_capacity: input.capacity,
    p_file_name: input.fileName,
    p_row_count: input.rowCount,
  });
  if (error) throw new Error(cleanError(error.message));
  return data as WriteResult;
}

export async function deleteSalesCount(id: string): Promise<void> {
  const { error } = await supabase.rpc('exos_delete_sales_count', { p_id: id });
  if (error) throw new Error(cleanError(error.message));
}

/** "sales counts: at most 20 …" → "At most 20 …". */
export function cleanError(message: string): string {
  const m = message.replace(/^sales counts:\s*/i, '');
  if (/not authorized/i.test(m)) return 'Only owners, managers and finance can change these counts.';
  return m.charAt(0).toUpperCase() + m.slice(1);
}
