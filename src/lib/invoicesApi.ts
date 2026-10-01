// Reads and writes behind invoices / receipts (mig 20261001100000). Types and
// the rendering math are in ./invoices.ts.

import { supabase } from './supabase';
import type { EventInvoiceRow, InvoiceDocument, OrgLegal } from './invoices';

/** The printable document for an invoice; throws when missing or not the caller's. */
export async function getInvoiceDocument(invoiceId: string): Promise<InvoiceDocument> {
  const { data, error } = await supabase.rpc('exos_invoice_document', { p_invoice_id: invoiceId });
  if (error) throw error;
  return data as InvoiceDocument;
}

/** The printable document for a credit note (its invoice + the note). */
export async function getCreditNoteDocument(creditNoteId: string): Promise<InvoiceDocument> {
  const { data, error } = await supabase.rpc('exos_credit_note_document', { p_credit_note_id: creditNoteId });
  if (error) throw error;
  return data as InvoiceDocument;
}

export interface MyInvoice {
  id: string;
  number: string;
  sessionId: string | null;
  eventId: string | null;
  totalCents: number;
  currency: string;
  issuedAt: string;
  refundedCents: number;
}

/** The signed-in buyer's invoices (My Tickets "Receipt" links). [] when unavailable. */
export async function listMyInvoices(): Promise<MyInvoice[]> {
  try {
    const { data, error } = await supabase.rpc('exos_my_invoices');
    if (error) throw error;
    return ((data as any[]) ?? []).map((r) => ({
      id: r.id,
      number: r.number,
      sessionId: r.session_id ?? null,
      eventId: r.event_id ?? null,
      totalCents: Number(r.total_cents) || 0,
      currency: (r.currency || 'usd').toUpperCase(),
      issuedAt: r.issued_at,
      refundedCents: Number(r.refunded_cents) || 0,
    }));
  } catch (e) {
    console.warn('receipts unavailable (non-fatal):', (e as { message?: string })?.message ?? e);
    return [];
  }
}

/** An event's invoices with credited amounts (owner / manager / finance via RLS); [] when unavailable. */
export async function listEventInvoices(eventId: string): Promise<EventInvoiceRow[]> {
  const { data, error } = await supabase
    .from('exos_invoice_totals')
    .select('id, number, session_id, total_cents, currency, issued_at, refunded_cents')
    .eq('event_id', eventId)
    .order('issued_at', { ascending: true })
    .limit(5000);
  if (error) {
    console.warn('invoices unavailable (non-fatal):', error.message);
    return [];
  }
  return (data as EventInvoiceRow[] | null) ?? [];
}

const LEGAL_COLS = 'org_id, legal_name, legal_address, tax_id, invoice_footer, updated_at';

/** The org's legal details; empty strings when none are saved; null when unreadable. */
export async function getOrgLegal(orgId: string): Promise<OrgLegal | null> {
  const { data, error } = await supabase.from('exos_org_legal').select(LEGAL_COLS).eq('org_id', orgId).maybeSingle();
  if (error) {
    console.warn('legal details unavailable (non-fatal):', error.message);
    return null;
  }
  const r = (data ?? {}) as Partial<Record<keyof OrgLegal, string | null>>;
  return {
    legal_name: r.legal_name ?? '',
    legal_address: r.legal_address ?? '',
    tax_id: r.tax_id ?? '',
    invoice_footer: r.invoice_footer ?? '',
  };
}

export async function saveOrgLegal(orgId: string, v: OrgLegal): Promise<void> {
  const clean = (s: string) => (s.trim() === '' ? null : s.trim());
  const { error } = await supabase.from('exos_org_legal').upsert(
    {
      org_id: orgId,
      legal_name: clean(v.legal_name),
      legal_address: clean(v.legal_address),
      tax_id: clean(v.tax_id),
      invoice_footer: clean(v.invoice_footer),
    },
    { onConflict: 'org_id' },
  );
  if (error) throw error;
}
