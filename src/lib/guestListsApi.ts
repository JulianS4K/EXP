// Guest lists (mig 20260926050000) — Supabase wrappers + the door's offline
// cache. Pure logic lives in ./guestLists and ./tables.
//
// Staff (owner / manager, or the member who owns a list) read lists through
// RLS and change them through RPCs. Promoters use their portal token. The
// door (owner / manager / scanner) downloads exos_event_door_extras — every
// guest (names only) plus table labels by ticket — and caches it in
// localStorage with a pending-arrival queue, like the ticket registry.

import { supabase } from './supabase';
import {
  mapGuestEntry,
  mapGuestListMeta,
  type GuestEntry,
  type GuestListMeta,
  type PendingArrival,
} from './guestLists';
import { mapDoorTable, type DoorTable } from './tables';
import { normalizeNeeds, type AccessNeed } from './accessibility';

export interface GuestList {
  id: string;
  eventId: string;
  name: string;
  ownerUid: string | null;
  promoterId: string | null;
  cap: number | null;
  maxPlusOnes: number;
  countsTowardCapacity: boolean;
  status: 'open' | 'closed';
  closesAt: string | null;
}

export interface GuestListInput {
  name: string;
  cap?: number | null;
  promoterId?: string | null;
  countsTowardCapacity?: boolean;
  maxPlusOnes?: number;
  status?: 'open' | 'closed';
  closesAt?: string | null;
}

function mapList(r: any): GuestList {
  return {
    id: r.id,
    eventId: r.event_id,
    name: r.name,
    ownerUid: r.owner_uid ?? null,
    promoterId: r.promoter_id ?? null,
    cap: r.cap ?? null,
    maxPlusOnes: Number(r.max_plus_ones ?? 5),
    countsTowardCapacity: !!r.counts_toward_capacity,
    status: r.status === 'closed' ? 'closed' : 'open',
    closesAt: r.closes_at ?? null,
  };
}

export async function listGuestLists(eventId: string): Promise<{ lists: GuestList[]; entries: GuestEntry[] }> {
  const [{ data: lists, error: e1 }, { data: entries, error: e2 }] = await Promise.all([
    supabase.from('exos_guest_lists').select('*').eq('event_id', eventId).order('created_at', { ascending: true }),
    supabase
      .from('exos_guest_list_entries')
      .select('id, list_id, guest_name, email, phone, plus_ones, arrived, arrived_at, note')
      .eq('event_id', eventId)
      .order('guest_name', { ascending: true }),
  ]);
  if (e1) throw e1;
  if (e2) throw e2;
  return { lists: (lists ?? []).map(mapList), entries: (entries ?? []).map(mapGuestEntry) };
}

export async function upsertGuestList(eventId: string, input: GuestListInput, listId?: string): Promise<string> {
  const { data, error } = await supabase.rpc('exos_upsert_guest_list', {
    p_event_id: eventId,
    p_name: input.name,
    p_cap: input.cap ?? null,
    p_promoter_id: input.promoterId ?? null,
    p_counts_toward_capacity: input.countsTowardCapacity ?? false,
    p_max_plus_ones: input.maxPlusOnes ?? 5,
    p_list_id: listId ?? null,
    p_status: input.status ?? 'open',
    p_closes_at: input.closesAt ?? null,
  });
  if (error) throw error;
  return data as string;
}

export async function deleteGuestList(listId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_delete_guest_list', { p_list_id: listId });
  if (error) throw error;
}

export interface GuestInput {
  guestName: string;
  plusOnes: number;
  email?: string;
  phone?: string;
  note?: string;
}

export async function addGuest(listId: string, g: GuestInput): Promise<string> {
  const { data, error } = await supabase.rpc('exos_add_guest', {
    p_list_id: listId, p_guest_name: g.guestName, p_email: g.email || null, p_phone: g.phone || null,
    p_plus_ones: g.plusOnes, p_note: g.note || null,
  });
  if (error) throw error;
  return data as string;
}

export async function updateGuest(entryId: string, g: GuestInput): Promise<void> {
  const { error } = await supabase.rpc('exos_update_guest', {
    p_entry_id: entryId, p_guest_name: g.guestName, p_email: g.email || null, p_phone: g.phone || null,
    p_plus_ones: g.plusOnes, p_note: g.note || null,
  });
  if (error) throw error;
}

export async function removeGuest(entryId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_remove_guest', { p_entry_id: entryId });
  if (error) throw error;
}

// --- Promoter portal (token) -------------------------------------------------

export interface PromoterGuestList {
  listId: string;
  name: string;
  cap: number | null;
  maxPlusOnes: number;
  open: boolean;
  closesAt: string | null;
  eventId: string;
  eventName: string;
  startsAt: string | null;
  heads: number;
  entries: { id: string; guestName: string; plusOnes: number; arrived: number; accessNeeds: AccessNeed[] }[];
}

export async function getPromoterGuestLists(token: string): Promise<PromoterGuestList[]> {
  const { data, error } = await supabase.rpc('exos_promoter_guest_lists', { p_token: token });
  if (error) throw error;
  return ((data as any[]) ?? []).map((r) => ({
    listId: r.list_id, name: r.name, cap: r.cap ?? null, maxPlusOnes: Number(r.max_plus_ones ?? 0),
    open: !!r.open, closesAt: r.closes_at ?? null, eventId: r.event_id, eventName: r.event_name,
    startsAt: r.starts_at ?? null, heads: Number(r.heads) || 0,
    entries: (r.entries ?? []).map((e: any) => ({
      id: e.id, guestName: e.guest_name, plusOnes: Number(e.plus_ones) || 0, arrived: Number(e.arrived) || 0,
      accessNeeds: normalizeNeeds(e.access_needs),
    })),
  }));
}

export async function promoterAddGuest(
  token: string, listId: string, g: { guestName: string; plusOnes: number; email?: string; phone?: string },
): Promise<string> {
  const { data, error } = await supabase.rpc('exos_promoter_add_guest', {
    p_token: token, p_list_id: listId, p_guest_name: g.guestName, p_plus_ones: g.plusOnes,
    p_email: g.email || null, p_phone: g.phone || null,
  });
  if (error) throw error;
  return data as string;
}

export async function promoterRemoveGuest(token: string, entryId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_promoter_remove_guest', { p_token: token, p_entry_id: entryId });
  if (error) throw error;
}

// --- Door ------------------------------------------------------------------------

export interface DoorExtras {
  tables: DoorTable[];
  lists: GuestListMeta[];
  guests: GuestEntry[];
  /** Access needs by ticket id (mig 20260926090000). */
  ticketAccess?: Record<string, AccessNeed[]>;
}

export async function getDoorExtras(eventId: string): Promise<DoorExtras> {
  const { data, error } = await supabase.rpc('exos_event_door_extras', { p_event_id: eventId });
  if (error) throw error;
  const d = (data ?? {}) as any;
  return {
    tables: (d.tables ?? []).map(mapDoorTable),
    lists: (d.lists ?? []).map(mapGuestListMeta),
    guests: (d.guests ?? []).map(mapGuestEntry),
    ticketAccess: Object.fromEntries(
      Object.entries((d.ticket_access ?? {}) as Record<string, unknown>).map(([k, v]) => [k, normalizeNeeds(v)]),
    ),
  };
}

export interface GuestCheckInResult {
  ok: boolean;
  reason: string;
  arrived?: number;
  party?: number;
  remaining?: number;
}

export async function guestCheckIn(
  eventId: string, entryId: string, count: number, clientRef: string, source: 'online' | 'offline-sync' = 'online',
): Promise<GuestCheckInResult> {
  const { data, error } = await supabase.rpc('exos_guest_check_in', {
    p_entry_id: entryId, p_count: count, p_event_id: eventId, p_client_ref: clientRef, p_source: source,
  });
  if (error) throw error;
  return (data ?? { ok: false, reason: 'unknown' }) as GuestCheckInResult;
}

// Offline cache, same 7-day TTL as the ticket registry.
const TTL_MS = 7 * 24 * 60 * 60 * 1000;
const extrasKey = (eventId: string) => `doorextras_${eventId}`;
const pendingKey = (eventId: string) => `guest_pending_${eventId}`;

export function loadCachedDoorExtras(eventId: string): DoorExtras | null {
  try {
    const raw = localStorage.getItem(extrasKey(eventId));
    if (!raw) return null;
    const p = JSON.parse(raw);
    if (!p || typeof p._savedAt !== 'number' || Date.now() - p._savedAt > TTL_MS) {
      localStorage.removeItem(extrasKey(eventId));
      return null;
    }
    return p.data as DoorExtras;
  } catch {
    return null;
  }
}

export function saveCachedDoorExtras(eventId: string, data: DoorExtras): void {
  try {
    localStorage.setItem(extrasKey(eventId), JSON.stringify({ _savedAt: Date.now(), data }));
  } catch {
    /* quota / private mode — the door still works online */
  }
}

export function loadPendingArrivals(eventId: string): PendingArrival[] {
  try {
    const raw = localStorage.getItem(pendingKey(eventId));
    const p = raw ? JSON.parse(raw) : [];
    return Array.isArray(p) ? p : [];
  } catch {
    return [];
  }
}

export function savePendingArrivals(eventId: string, q: PendingArrival[]): void {
  try {
    if (q.length === 0) localStorage.removeItem(pendingKey(eventId));
    else localStorage.setItem(pendingKey(eventId), JSON.stringify(q));
  } catch {
    /* ignore */
  }
}

/** Drop other events' stale door caches (pending queues are kept until synced). */
export function pruneStaleDoorExtras(): void {
  try {
    const now = Date.now();
    const drop: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (!k || !k.startsWith('doorextras_')) continue;
      try {
        const p = JSON.parse(localStorage.getItem(k) || 'null');
        if (!p || typeof p._savedAt !== 'number' || now - p._savedAt > TTL_MS) drop.push(k);
      } catch {
        drop.push(k);
      }
    }
    drop.forEach((k) => localStorage.removeItem(k));
  } catch {
    /* ignore */
  }
}
