// Templates, rental invoices and booking requests: the dashboard's data
// layer (mig 20261102130000, docs/templates-inbound.md). Templates and the
// form settings are rows the signed-in user writes (RLS + triggers decide);
// rental invoices, reviews, holds from requests and deleting an event go
// through the exos_* functions. The public form calls the two anon RPCs.

import { supabase } from './supabase';
import type { RentalDeposit, RentalItem, RentalStatus, RentalTaxFee } from './rentalInvoice';
import type { InboundStatus } from './inbound';

export type TemplateStatus = 'active' | 'archived';

export interface EventTemplateTier {
  name: string;
  description?: string;
  price_cents: number;
  capacity: number;
  ticket_type?: 'paid' | 'free' | 'donation';
  visibility?: 'public' | 'hidden';
  sort_order?: number;
}

export interface EventTemplateFee {
  name: string;
  recipient?: string;
  kind: 'passed_on' | 'absorbed';
  calc: 'fixed' | 'percent';
  amount_cents?: number;
  percent?: number;
  per?: 'ticket' | 'order';
}

export interface EventTemplateRow {
  id: string;
  org_id: string;
  name: string;
  status: TemplateStatus;
  event_name: string | null;
  description: string;
  capacity: number | null;
  doors_offset_minutes: number | null;
  duration_minutes: number | null;
  event_fields: Record<string, unknown>;
  tiers: EventTemplateTier[];
  fee_rules: EventTemplateFee[];
  inherit_org_fees: boolean;
  use_count: number;
  last_used_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface NoteTemplateRow {
  id: string;
  org_id: string;
  title: string;
  body: string;
  status: TemplateStatus;
  created_at: string;
  updated_at: string;
}

export interface RentalTemplateRow {
  id: string;
  org_id: string;
  title: string;
  status: TemplateStatus;
  currency: string;
  payee_name: string | null;
  notes: string;
  terms: string;
  attendance_count: number | null;
  discount_cents: number;
  items: RentalItem[];
  deposits: RentalDeposit[];
  tax_fees: RentalTaxFee[];
  created_at: string;
  updated_at: string;
}

export interface RentalInvoiceRow extends Omit<RentalTemplateRow, 'status'> {
  template_id: string | null;
  status: RentalStatus;
  number: string | null;
  number_seq: number | null;
  bill_to_name: string | null;
  bill_to_email: string | null;
  subtotal_cents: number;
  tax_cents: number;
  total_cents: number;
  deposits_cents: number;
  hold_id: string | null;
  hold_position_id: string | null;
  venue_id: string | null;
  room_id: string | null;
  rental_date: string | null;
  event_id: string | null;
  due_on: string | null;
  issued_at: string | null;
  paid_at: string | null;
  voided_at: string | null;
  void_reason: string | null;
}

export interface InboundRow {
  id: string;
  org_id: string;
  status: InboundStatus;
  source: 'form' | 'api';
  artist_name: string;
  contact_name: string | null;
  contact_role: string | null;
  email: string | null;
  phone: string | null;
  company: string | null;
  message: string;
  links: Record<string, string>;
  genres: string[];
  venue_id: string | null;
  preferred_dates: string[];
  dates_flexible: boolean;
  expected_draw: number | null;
  hold_id: string | null;
  staff_note: string;
  reviewed_by: string | null;
  reviewed_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface InboundSettings {
  org_id: string;
  enabled: boolean;
  title: string | null;
  intro: string | null;
  venue_ids: string[];
}

export interface InboundPublicForm {
  org_name: string;
  org_slug: string;
  title: string;
  intro: string | null;
  venues: { id: string; name: string }[];
}

/** The database's message without its prefix, first letter up. */
function clean(error: { message?: string; code?: string }): Error & { code?: string } {
  let msg = String(error.message ?? 'Request failed').replace(/^exos_[a-z_]+:\s*/, '');
  if (/row-level security|permission denied|not authorized/.test(msg)) msg = "You don't have access to do that.";
  const e = new Error(msg.charAt(0).toUpperCase() + msg.slice(1)) as Error & { code?: string };
  e.code = error.code;
  return e;
}

async function run<T>(p: PromiseLike<{ data: T; error: { message?: string; code?: string } | null }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw clean(error);
  return data;
}

// ---- Event templates ---------------------------------------------------------------

export async function listEventTemplates(orgId: string): Promise<EventTemplateRow[]> {
  return (await run(supabase.from('exos_event_templates').select('*').eq('org_id', orgId).order('name'))) as EventTemplateRow[];
}

export async function saveEventTemplate(orgId: string, t: Partial<EventTemplateRow>, id?: string): Promise<void> {
  const { id: _i, org_id: _o, use_count: _u, last_used_at: _l, created_at: _c, updated_at: _up, ...row } = t;
  if (id) await run(supabase.from('exos_event_templates').update(row).eq('id', id));
  else await run(supabase.from('exos_event_templates').insert({ ...row, org_id: orgId }));
}

export async function deleteEventTemplate(id: string): Promise<void> {
  await run(supabase.from('exos_event_templates').delete().eq('id', id));
}

/** A draft event from the template; returns its id. */
export async function createEventFromTemplate(id: string, args: { name?: string; starts_at?: string; timezone?: string }): Promise<string> {
  const r = (await run(supabase.rpc('exos_event_from_template', { p_template_id: id, p_args: args }))) as { event_id: string };
  return r.event_id;
}

/** Save one of the org's events as a template; returns the template id. */
export async function saveEventAsTemplate(eventId: string, name?: string): Promise<string> {
  return (await run(supabase.rpc('exos_event_template_from_event', { p_event_id: eventId, p_name: name ?? null }))) as string;
}

/** Delete a draft event that never sold (else the error says to cancel it). */
export async function deleteDraftEvent(eventId: string): Promise<void> {
  await run(supabase.rpc('exos_event_delete', { p_event_id: eventId }));
}

// ---- Note templates -------------------------------------------------------------------

export async function listNoteTemplates(orgId: string): Promise<NoteTemplateRow[]> {
  return (await run(supabase.from('exos_note_templates').select('*').eq('org_id', orgId).order('title'))) as NoteTemplateRow[];
}

export async function saveNoteTemplate(orgId: string, t: Pick<NoteTemplateRow, 'title' | 'body'> & { status?: TemplateStatus }, id?: string): Promise<void> {
  if (id) await run(supabase.from('exos_note_templates').update(t).eq('id', id));
  else await run(supabase.from('exos_note_templates').insert({ ...t, org_id: orgId }));
}

export async function deleteNoteTemplate(id: string): Promise<void> {
  await run(supabase.from('exos_note_templates').delete().eq('id', id));
}

/** Add the template's body as a staff note on an event. */
export async function applyNoteTemplate(orgId: string, t: NoteTemplateRow, eventId: string): Promise<void> {
  await run(supabase.from('exos_event_notes').insert({ org_id: orgId, event_id: eventId, body: t.body }));
}

// ---- Rental invoice templates and invoices -----------------------------------------------

export async function listRentalTemplates(orgId: string): Promise<RentalTemplateRow[]> {
  return (await run(supabase.from('exos_rental_invoice_templates').select('*').eq('org_id', orgId).order('title'))) as RentalTemplateRow[];
}

export async function saveRentalTemplate(orgId: string, t: Partial<RentalTemplateRow>, id?: string): Promise<void> {
  const { id: _i, org_id: _o, created_at: _c, updated_at: _u, ...row } = t;
  if (id) await run(supabase.from('exos_rental_invoice_templates').update(row).eq('id', id));
  else await run(supabase.from('exos_rental_invoice_templates').insert({ ...row, org_id: orgId }));
}

export async function deleteRentalTemplate(id: string): Promise<void> {
  await run(supabase.from('exos_rental_invoice_templates').delete().eq('id', id));
}

export async function listRentalInvoices(orgId: string): Promise<RentalInvoiceRow[]> {
  return (await run(supabase.from('exos_rental_invoices').select('*').eq('org_id', orgId)
    .order('created_at', { ascending: false }).limit(1000))) as RentalInvoiceRow[];
}

export async function createRentalInvoice(orgId: string, body: Record<string, unknown>): Promise<RentalInvoiceRow> {
  return (await run(supabase.rpc('exos_rental_invoice_create', { p_org_id: orgId, p_invoice: body }))) as RentalInvoiceRow;
}

export async function updateRentalInvoice(id: string, patch: Record<string, unknown>): Promise<RentalInvoiceRow> {
  return (await run(supabase.rpc('exos_rental_invoice_update', { p_id: id, p_patch: patch }))) as RentalInvoiceRow;
}

export async function issueRentalInvoice(id: string, dueOn?: string | null): Promise<RentalInvoiceRow> {
  return (await run(supabase.rpc('exos_rental_invoice_issue', { p_id: id, p_due_on: dueOn ?? null }))) as RentalInvoiceRow;
}

export async function setRentalInvoiceStatus(id: string, status: 'paid' | 'issued' | 'void', reason?: string): Promise<RentalInvoiceRow> {
  return (await run(supabase.rpc('exos_rental_invoice_set_status', { p_id: id, p_status: status, p_reason: reason ?? null }))) as RentalInvoiceRow;
}

export async function deleteRentalInvoice(id: string): Promise<void> {
  await run(supabase.rpc('exos_rental_invoice_delete', { p_id: id }));
}

export async function getRentalPrefix(orgId: string): Promise<string> {
  const r = (await run(supabase.from('exos_rental_invoice_counters').select('prefix').eq('org_id', orgId).maybeSingle())) as { prefix: string } | null;
  return r?.prefix ?? 'R-';
}

export async function setRentalPrefix(orgId: string, prefix: string): Promise<string> {
  return (await run(supabase.rpc('exos_rental_invoice_prefix_set', { p_org_id: orgId, p_prefix: prefix }))) as string;
}

// ---- Booking requests ---------------------------------------------------------------------

const INBOUND_COLS =
  'id, org_id, status, source, artist_name, contact_name, contact_role, email, phone, company, message, links, genres, ' +
  'venue_id, preferred_dates, dates_flexible, expected_draw, hold_id, staff_note, reviewed_by, reviewed_at, created_at, updated_at';

export async function listInbound(orgId: string): Promise<InboundRow[]> {
  return (await run(supabase.from('exos_inbound_submissions').select(INBOUND_COLS).eq('org_id', orgId)
    .order('created_at', { ascending: false }).limit(1000))) as unknown as InboundRow[];
}

export async function setInboundStatus(id: string, status: InboundStatus | null, note?: string | null): Promise<void> {
  await run(supabase.rpc('exos_inbound_set_status', { p_id: id, p_status: status, p_note: note ?? null }));
}

export async function deleteInbound(id: string): Promise<void> {
  await run(supabase.from('exos_inbound_submissions').delete().eq('id', id));
}

/** Hold the request's dates at a venue (one night per date); returns the hold id. */
export async function holdFromInbound(id: string, venueId: string, dates: string[], roomId?: string | null): Promise<string> {
  const r = (await run(supabase.rpc('exos_inbound_create_hold', {
    p_id: id, p_hold: { positions: dates.map((date) => ({ date, venue_id: venueId, ...(roomId ? { room_id: roomId } : {}) })) },
  }))) as { hold: { id: string } };
  return r.hold.id;
}

export async function getInboundSettings(orgId: string): Promise<InboundSettings | null> {
  return (await run(supabase.from('exos_inbound_settings').select('org_id, enabled, title, intro, venue_ids').eq('org_id', orgId)
    .maybeSingle())) as InboundSettings | null;
}

export async function saveInboundSettings(orgId: string, s: Omit<InboundSettings, 'org_id'>): Promise<void> {
  await run(supabase.from('exos_inbound_settings').upsert({ ...s, org_id: orgId }, { onConflict: 'org_id' }));
}

export async function getInboundForm(slug: string): Promise<InboundPublicForm | null> {
  return (await run(supabase.rpc('exos_inbound_form_public', { p_org_slug: slug }))) as InboundPublicForm | null;
}

/** The public form's submit. Throws the RPC error (code kept) for inboundErrorMessage. */
export async function submitInbound(slug: string, payload: Record<string, unknown>): Promise<void> {
  const { error } = await supabase.rpc('exos_inbound_submit', { p_org_slug: slug, p_submission: payload });
  if (error) throw error;
}
