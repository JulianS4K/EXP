// Phone-number RSVP (mig 20261102150000, docs/organizer-guide.md "Phone
// RSVP"): the guest page talks to exos-rsvp; organizers set it per event;
// a guest later saves a ticket to their account from its link. The pure
// rules are shared with the function (supabase/functions/_shared/rsvp.ts).

import { supabase } from './supabase';

export { codeSentText, maskPhone, normalizeRsvpPhone, rsvpErrorMessage } from '../../supabase/functions/_shared/rsvp.ts';

export interface RsvpInfo { ok: boolean; reason: string; tier_name: string | null; max_plus_ones: number; sms: boolean }
export interface RsvpStart { ok: boolean; error?: string; rsvp_id?: string; channel?: 'sms' | 'email'; to?: string; max_plus_ones?: number }
export interface RsvpVerify { ok: boolean; error?: string; attempts_left?: number; event_id?: string; tickets?: { id: string; url: string | null }[] }

async function call<T>(body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke('exos-rsvp', { body });
  if (error) {
    // Non-2xx answers still carry { ok:false, error } in the body.
    const ctx = (error as { context?: Response }).context;
    const parsed = ctx && typeof ctx.json === 'function' ? await ctx.json().catch(() => null) : null;
    if (parsed && typeof parsed === 'object') return parsed as T;
    return { ok: false, error: 'unavailable' } as T;
  }
  return data as T;
}

export const rsvpInfo = (eventId: string) => call<RsvpInfo>({ action: 'info', event_id: eventId });

export const rsvpStart = (input: {
  eventId: string; name: string; phone: string; email?: string; plusOnes: number; promoter?: string | null; website?: string;
}) => call<RsvpStart>({
  action: 'start', event_id: input.eventId, name: input.name, phone: input.phone, email: input.email || null,
  plus_ones: input.plusOnes, promoter: input.promoter || null, website: input.website ?? '',
});

export const rsvpVerify = (rsvpId: string, code: string) => call<RsvpVerify>({ action: 'verify', rsvp_id: rsvpId, code });

/** The ticket page path from a full link (the key stays in the fragment). */
export function ticketPathFromUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  const m = /\/t\/([0-9a-f-]{36})#k=([A-Za-z0-9_-]{43})$/i.exec(url);
  return m ? `/t/${m[1]}#k=${m[2]}` : null;
}

/** Signed in: move a phone-RSVP ticket into this account (its link key proves you hold it). */
export async function claimRsvpTicket(ticketId: string, key: string): Promise<{ ok: boolean; error?: string }> {
  const { data, error } = await supabase.rpc('exos_phone_rsvp_claim', { p_ticket_id: ticketId, p_key: key });
  if (error) throw error;
  return data as { ok: boolean; error?: string };
}

// --- Organizer ---------------------------------------------------------------
export interface PhoneRsvpSettings { enabled: boolean; tierId: string | null; maxPlusOnes: number }

/** null: not available on this database or not visible to this role. */
export async function getPhoneRsvpSettings(eventId: string): Promise<PhoneRsvpSettings | null> {
  const { data, error } = await supabase
    .from('exos_phone_rsvp_settings').select('enabled, tier_id, max_plus_ones').eq('event_id', eventId).maybeSingle();
  if (error) return null;
  return { enabled: !!data?.enabled, tierId: data?.tier_id ?? null, maxPlusOnes: Number(data?.max_plus_ones ?? 0) };
}

export async function setPhoneRsvpSettings(eventId: string, s: PhoneRsvpSettings): Promise<void> {
  const { error } = await supabase.rpc('exos_set_phone_rsvp', {
    p_event_id: eventId, p_enabled: s.enabled, p_tier_id: s.tierId, p_max_plus_ones: s.maxPlusOnes,
  });
  if (error) throw error;
}

export interface PhoneRsvpRow { id: string; guestName: string; phone: string; plusOnes: number; status: string; channel: string; createdAt: string }

/** Owner / manager (RLS). Confirmed and pending ones, newest first. */
export async function listPhoneRsvps(eventId: string): Promise<PhoneRsvpRow[] | null> {
  const { data, error } = await supabase
    .from('exos_phone_rsvps')
    .select('id, guest_name, phone, plus_ones, status, channel, created_at')
    .eq('event_id', eventId)
    .in('status', ['confirmed', 'sold_out'])
    .order('created_at', { ascending: false })
    .limit(500);
  if (error) return null;
  return (data ?? []).map((r: any) => ({
    id: r.id, guestName: r.guest_name, phone: r.phone, plusOnes: r.plus_ones, status: r.status, channel: r.channel, createdAt: r.created_at,
  }));
}

/** Heads expected from confirmed phone RSVPs (guest + plus-ones). */
export function rsvpHeads(rows: Pick<PhoneRsvpRow, 'status' | 'plusOnes'>[]): number {
  return rows.filter((r) => r.status === 'confirmed').reduce((n, r) => n + 1 + Math.max(0, Math.trunc(r.plusOnes)), 0);
}
