// Reads behind the money journal (mig 20261108100000, docs/journal.md): the
// trial balance, the journal lines (for the CSV) and the sales-tax report.
// Read-only; RLS and the RPCs keep them to the org's owner / manager /
// finance. Each read answers null when it can't be read (an older schema, no
// access), and the screens hide. The math is in ./journal.ts.

import { supabase } from './supabase';
import { fetchAllPages } from './pagedRead';
import type { JournalLineRow, SalesTaxRow, TrialBalanceRow } from './journal';

const PAGE = 1000;
const LINE_COLS =
  'line_id, entry_id, entry_number, occurred_at, currency, source_table, source_id, kind, account, account_name, ' +
  'debit_cents, credit_cents, memo, line_no, event_id';

export interface Period {
  from: string | null;
  to: string | null;
  eventId?: string | null;
}

export async function getTrialBalance(orgId: string, p: Period): Promise<TrialBalanceRow[] | null> {
  const { data, error } = await supabase.rpc('exos_journal_trial_balance', {
    p_org: orgId, p_from: p.from, p_to: p.to, p_event: p.eventId ?? null,
  });
  if (error) {
    console.warn('trial balance unavailable (non-fatal):', error.message);
    return null;
  }
  return (data as TrialBalanceRow[] | null) ?? [];
}

/** Every journal line of the org in the period (paged through). */
export async function listJournalLines(orgId: string, p: Period): Promise<JournalLineRow[] | null> {
  try {
    return await fetchAllPages<JournalLineRow>(async (from, to) => {
      let q = supabase.from('exos_journal_rows').select(LINE_COLS).eq('org_id', orgId);
      if (p.from) q = q.gte('occurred_at', p.from);
      if (p.to) q = q.lt('occurred_at', p.to);
      if (p.eventId) q = q.eq('event_id', p.eventId);
      const { data, error } = await q.order('occurred_at').order('entry_number').order('line_no').range(from, to);
      if (error) throw error;
      return (data as unknown as JournalLineRow[] | null) ?? [];
    }, (r) => String(r.line_id), PAGE);
  } catch (e) {
    console.warn('journal unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return null;
  }
}

export async function getSalesTax(orgId: string, p: Period): Promise<SalesTaxRow[] | null> {
  const { data, error } = await supabase.rpc('exos_sales_tax_report', {
    p_org: orgId, p_from: p.from, p_to: p.to, p_event: p.eventId ?? null,
  });
  if (error) {
    console.warn('sales tax report unavailable (non-fatal):', error.message);
    return null;
  }
  return ((data as { rows?: SalesTaxRow[] } | null)?.rows) ?? [];
}
