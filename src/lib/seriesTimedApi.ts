// RPC wrappers for series, collections and timed entry (mig 20261030150000,
// docs/series-timed-entry.md). Every rule lives in SQL; these only map
// shapes. The pure maths is in ./recurrence, ./timedEntry and ./slots.

import { supabase } from './supabase';
import type { SeriesRule } from './recurrence';
import type { OpeningRange, TimedEntryConfig } from './timedEntry';
import type { PublicSlot, SlotReportRow } from './slots';

// -- Series ---------------------------------------------------------------------------

export type SeriesStatus = 'active' | 'archived' | 'cancelled';
export type OccurrenceStatus = 'generated' | 'cancelled' | 'skipped' | 'removed';

export interface SeriesRow {
  id: string;
  orgId: string;
  name: string;
  status: SeriesStatus;
  description: string | null;
  imageUrl: string | null;
  templateEventId: string | null;
  timezone: string;
  rule: SeriesRule | null;
  createdAt: string;
}

export interface OccurrenceRow {
  date: string;
  time: string;
  startsAt: string;
  eventId: string | null;
  status: OccurrenceStatus;
  /** Joined from the event (staff read). */
  event?: { name: string; status: string; ticketsSold: number; totalTickets: number } | null;
}

export interface SeriesSkip { date?: string; event_id?: string; field?: string; reason: string }

function mapSeries(r: any): SeriesRow {
  return {
    id: String(r.id), orgId: String(r.org_id), name: String(r.name ?? ''), status: (r.status ?? 'active') as SeriesStatus,
    description: r.description ?? null, imageUrl: r.image_url ?? null, templateEventId: r.template_event_id ?? null,
    timezone: r.timezone || 'UTC', rule: (r.rule ?? null) as SeriesRule | null, createdAt: String(r.created_at ?? ''),
  };
}

export async function listOrgSeries(orgId: string): Promise<SeriesRow[]> {
  const { data, error } = await supabase.from('exos_event_series').select('*').eq('org_id', orgId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map(mapSeries);
}

export async function getSeries(seriesId: string): Promise<SeriesRow | null> {
  const { data, error } = await supabase.from('exos_event_series').select('*').eq('id', seriesId).maybeSingle();
  if (error) throw error;
  return data ? mapSeries(data) : null;
}

export async function listOccurrences(seriesId: string): Promise<OccurrenceRow[]> {
  const { data, error } = await supabase.from('exos_series_occurrences')
    .select('occ_date, occ_time, starts_at, event_id, status').eq('series_id', seriesId).order('occ_date');
  if (error) throw error;
  const rows = (data ?? []) as any[];
  const ids = rows.map((r) => r.event_id).filter(Boolean);
  const events = new Map<string, any>();
  if (ids.length) {
    const { data: evs, error: e2 } = await supabase.from('exos_events')
      .select('id, name, status, tickets_sold, total_tickets').in('id', ids);
    if (e2) throw e2;
    for (const e of evs ?? []) events.set(String((e as any).id), e);
  }
  return rows.map((r) => {
    const e = r.event_id ? events.get(String(r.event_id)) : null;
    return {
      date: String(r.occ_date), time: String(r.occ_time).slice(0, 5), startsAt: String(r.starts_at),
      eventId: r.event_id ?? null, status: r.status as OccurrenceStatus,
      event: e ? { name: e.name, status: e.status, ticketsSold: Number(e.tickets_sold) || 0, totalTickets: Number(e.total_tickets) || 0 } : null,
    };
  });
}

export async function createSeries(templateEventId: string, name: string, rule: SeriesRule, description?: string | null): Promise<string> {
  const { data, error } = await supabase.rpc('exos_series_create', {
    p_template_event_id: templateEventId, p_name: name, p_rule: rule, p_description: description ?? null,
  });
  if (error) throw error;
  return String(data);
}

export async function generateSeriesDates(seriesId: string, dates: { date: string; time: string }[]):
  Promise<{ created: { date: string; event_id: string }[]; skipped: SeriesSkip[] }> {
  const { data, error } = await supabase.rpc('exos_series_generate', { p_series_id: seriesId, p_dates: dates });
  if (error) throw error;
  return (data ?? { created: [], skipped: [] }) as { created: { date: string; event_id: string }[]; skipped: SeriesSkip[] };
}

export async function publishSeries(seriesId: string): Promise<number> {
  const { data, error } = await supabase.rpc('exos_series_publish', { p_series_id: seriesId });
  if (error) throw error;
  return Number(data) || 0;
}

export async function cancelSeriesDate(seriesId: string, date: string, reason?: string):
  Promise<{ date: string; status: OccurrenceStatus; event_id: string | null }> {
  const { data, error } = await supabase.rpc('exos_series_cancel_date', { p_series_id: seriesId, p_date: date, p_reason: reason ?? null });
  if (error) throw error;
  return data as { date: string; status: OccurrenceStatus; event_id: string | null };
}

export interface PropagateChanges {
  name?: string;
  description?: string;
  image_url?: string;
  /** Tier name → new price. */
  prices?: Record<string, number>;
}

export async function propagateSeries(seriesId: string, changes: PropagateChanges):
  Promise<{ changed: { event_id: string; date: string; fields: string[] }[]; skipped: SeriesSkip[] }> {
  const { data, error } = await supabase.rpc('exos_series_propagate', { p_series_id: seriesId, p_changes: changes });
  if (error) throw error;
  return data as { changed: { event_id: string; date: string; fields: string[] }[]; skipped: SeriesSkip[] };
}

export async function updateSeries(seriesId: string, patch: {
  name?: string; description?: string | null; image_url?: string | null; rule?: SeriesRule; status?: 'active' | 'archived';
}): Promise<SeriesRow> {
  const { data, error } = await supabase.rpc('exos_series_update', { p_series_id: seriesId, p_patch: patch });
  if (error) throw error;
  return mapSeries(data);
}

export async function cancelSeries(seriesId: string, scope: 'series_only' | 'all_shows' | 'selected', eventIds?: string[], reason?: string):
  Promise<{ cancelled_event_ids: string[] }> {
  const { data, error } = await supabase.rpc('exos_series_cancel', {
    p_series_id: seriesId, p_scope: scope, p_event_ids: eventIds ?? null, p_reason: reason ?? null,
  });
  if (error) throw error;
  return data as { cancelled_event_ids: string[] };
}

export async function deleteSeries(seriesId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_series_delete', { p_series_id: seriesId });
  if (error) throw error;
}

export async function attachSeriesEvent(seriesId: string, eventId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_series_attach_event', { p_series_id: seriesId, p_event_id: eventId });
  if (error) throw error;
}

export async function detachSeriesEvent(seriesId: string, eventId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_series_detach_event', { p_series_id: seriesId, p_event_id: eventId });
  if (error) throw error;
}

/** Other published dates of a series, soonest first (event page "More dates"). */
export async function listPublicSeriesDates(seriesId: string, exceptEventId?: string): Promise<{ id: string; name: string; startsAt: string }[]> {
  const { data, error } = await supabase.from('exos_public_events').select('id, name, starts_at')
    .eq('series_id', seriesId).gte('starts_at', new Date().toISOString()).order('starts_at').limit(20);
  if (error) throw error;
  return ((data ?? []) as any[]).filter((e) => e.id !== exceptEventId)
    .map((e) => ({ id: String(e.id), name: String(e.name ?? ''), startsAt: String(e.starts_at) }));
}

// -- Collections ----------------------------------------------------------------------

export type CollectionRuleKind = 'series' | 'artist' | 'venue' | 'tag';

export interface CollectionRow {
  id: string;
  orgId: string;
  name: string;
  slug: string;
  description: string | null;
  imageUrl: string | null;
  mode: 'manual' | 'rule';
  eventIds: string[];
  ruleKind: CollectionRuleKind | null;
  ruleValue: string | null;
  published: boolean;
}

function mapCollection(r: any): CollectionRow {
  return {
    id: String(r.id), orgId: String(r.org_id), name: String(r.name ?? ''), slug: String(r.slug ?? ''),
    description: r.description ?? null, imageUrl: r.image_url ?? null, mode: r.mode === 'rule' ? 'rule' : 'manual',
    eventIds: Array.isArray(r.event_ids) ? r.event_ids.map(String) : [], ruleKind: r.rule_kind ?? null,
    ruleValue: r.rule_value ?? null, published: !!r.published,
  };
}

export async function listCollections(orgId: string): Promise<CollectionRow[]> {
  const { data, error } = await supabase.from('exos_collections').select('*').eq('org_id', orgId)
    .order('sort_order').order('created_at');
  if (error) throw error;
  return (data ?? []).map(mapCollection);
}

export async function saveCollection(c: Omit<CollectionRow, 'id'> & { id?: string }): Promise<CollectionRow> {
  const row = {
    org_id: c.orgId, name: c.name.trim(), slug: c.slug, description: c.description || null, image_url: c.imageUrl || null,
    mode: c.mode, event_ids: c.mode === 'manual' ? c.eventIds : [],
    rule_kind: c.mode === 'rule' ? c.ruleKind : null, rule_value: c.mode === 'rule' ? (c.ruleValue || '').trim() || null : null,
    published: c.published,
  };
  const q = c.id
    ? supabase.from('exos_collections').update(row).eq('id', c.id).select('*').single()
    : supabase.from('exos_collections').insert(row).select('*').single();
  const { data, error } = await q;
  if (error) throw error;
  return mapCollection(data);
}

export async function deleteCollection(id: string): Promise<void> {
  const { error } = await supabase.from('exos_collections').delete().eq('id', id);
  if (error) throw error;
}

export async function collectionEventIds(id: string): Promise<string[]> {
  const { data, error } = await supabase.rpc('exos_collection_event_ids', { p_collection_id: id });
  if (error) throw error;
  return ((data ?? []) as unknown[]).map(String);
}

export interface PublicEventCard {
  id: string;
  name: string;
  slug: string | null;
  starts_at: string;
  ends_at: string | null;
  timezone: string | null;
  venue_name: string | null;
  venue_location: string | null;
  image_url: string | null;
  currency: string | null;
  from_price: number | null;
  sold_out: boolean;
}

export interface PublicCollection {
  id: string;
  name: string;
  slug: string;
  description: string | null;
  image_url: string | null;
  org: { name: string; slug: string };
  events: PublicEventCard[];
}

export async function getPublicCollection(orgSlug: string, slug: string): Promise<PublicCollection | null> {
  const { data, error } = await supabase.rpc('exos_public_collection', { p_org_slug: orgSlug, p_slug: slug });
  if (error) throw error;
  return (data ?? null) as PublicCollection | null;
}

// -- Timed entry ----------------------------------------------------------------------

export interface PublicTimedEntry extends TimedEntryConfig {
  timezone: string;
}

function mapConfig(r: any): PublicTimedEntry {
  return {
    tierIds: (r.tier_ids ?? []).map(String),
    slotMinutes: Number(r.slot_minutes),
    capacity: Number(r.capacity ?? 0),
    tierCapacity: (r.tier_capacity ?? {}) as Record<string, number>,
    entryWindowMinutes: r.entry_window_minutes ?? null,
    earlyEntryMinutes: Number(r.early_entry_minutes ?? 0),
    hours: (r.hours ?? {}) as Record<string, OpeningRange[]>,
    startDate: String(r.start_date),
    endDate: String(r.end_date),
    closedDates: (r.closed_dates ?? []).map(String),
    version: Number(r.version ?? 0),
    timezone: r.timezone || 'UTC',
  };
}

/** The slot picker's config; null when the event isn't timed. */
export async function getPublicTimedEntry(eventId: string): Promise<PublicTimedEntry | null> {
  const { data, error } = await supabase.rpc('exos_public_timed_entry', { p_event_id: eventId });
  if (error) {
    // Before the migration: nothing is timed.
    if (error.code === 'PGRST202' || error.code === '42883') return null;
    throw error;
  }
  return data ? mapConfig(data) : null;
}

/** Staff: the saved config (with capacity), or null. */
export async function getTimedEntry(eventId: string): Promise<(TimedEntryConfig & { eventId: string }) | null> {
  const { data, error } = await supabase.from('exos_timed_entry').select('*').eq('event_id', eventId).maybeSingle();
  if (error) {
    if (error.code === '42P01' || error.code === 'PGRST205') return null;
    throw error;
  }
  return data ? { ...mapConfig(data), eventId } : null;
}

export async function setTimedEntry(eventId: string, config: Omit<TimedEntryConfig, 'version'>): Promise<void> {
  const { error } = await supabase.rpc('exos_set_timed_entry', { p_event_id: eventId, p_config: config });
  if (error) throw error;
}

export async function clearTimedEntry(eventId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_clear_timed_entry', { p_event_id: eventId });
  if (error) throw error;
}

export async function getPublicSlots(eventId: string, from: string, to: string): Promise<PublicSlot[]> {
  const { data, error } = await supabase.rpc('exos_public_event_slots', { p_event_id: eventId, p_from: from, p_to: to });
  if (error) throw error;
  return ((data ?? []) as any[]).map((r) => ({
    slotId: String(r.slot_id), date: String(r.slot_date), time: String(r.slot_time), startsAt: String(r.starts_at),
    endsAt: String(r.ends_at), entryUntil: String(r.entry_until), capacity: Number(r.capacity) || 0,
    remaining: Number(r.remaining) || 0, tierRemaining: (r.tier_remaining ?? {}) as Record<string, number>,
    closed: !!r.closed, ended: !!r.ended,
  }));
}

export async function getSlotReport(eventId: string, from?: string, to?: string): Promise<SlotReportRow[]> {
  const { data, error } = await supabase.rpc('exos_event_slot_report', { p_event_id: eventId, p_from: from ?? null, p_to: to ?? null });
  if (error) throw error;
  return ((data ?? []) as any[]).map((r) => ({
    slotId: String(r.slot_id), date: String(r.slot_date), time: String(r.slot_time), capacity: Number(r.capacity) || 0,
    custom: !!r.custom, closed: !!r.closed, sold: Number(r.sold) || 0, held: Number(r.held) || 0,
    checkedIn: Number(r.checked_in) || 0, gross: Number(r.gross) || 0, tierSold: (r.tier_sold ?? {}) as Record<string, number>,
  }));
}

export async function setEventSlot(eventId: string, slotId: string, change: { capacity?: number | null; closed?: boolean; reset?: boolean }): Promise<void> {
  const { error } = await supabase.rpc('exos_set_event_slot', {
    p_event_id: eventId, p_slot_id: slotId, p_capacity: change.capacity ?? null, p_closed: change.closed ?? null,
    p_reset: change.reset ?? false,
  });
  if (error) throw error;
}

export interface DoorSlotTicket {
  ticketId: string;
  slotId: string;
  slotStartsAt: string;
  entryFrom: string;
  entryUntil: string;
  status: string;
  checkInAt: string | null;
  override: boolean;
}

/** Door registry of slotted tickets (synced for offline use). */
export async function getDoorSlots(eventId: string): Promise<DoorSlotTicket[]> {
  const { data, error } = await supabase.rpc('exos_event_door_slots', { p_event_id: eventId });
  if (error) {
    if (error.code === 'PGRST202' || error.code === '42883') return [];
    throw error;
  }
  return ((data ?? []) as any[]).map((r) => ({
    ticketId: String(r.ticket_id), slotId: String(r.slot_id), slotStartsAt: String(r.slot_starts_at),
    entryFrom: String(r.entry_from), entryUntil: String(r.entry_until), status: String(r.status),
    checkInAt: r.check_in_at ?? null, override: !!r.admit_override,
  }));
}

/** "Admit anyway": the next live scan of the ticket passes the window check. */
export async function admitOutsideWindow(ticketId: string, eventId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_admit_outside_window', { p_ticket_id: ticketId, p_event_id: eventId });
  if (error) throw error;
}
