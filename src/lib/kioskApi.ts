// Kiosk mode (mig 20261113100000, docs/pos.md "Kiosk mode"): the calls.
//
// Setup (a signed-in owner / manager, RLS + the SQL role checks): the kiosk
// devices and their kiosk flag, starting kiosk mode on this screen (which
// keeps the credential and signs the member out), ending a session.
//
// The kiosk screen itself is signed out: every kiosk_* call to exos-pos
// carries only the kiosk's credential and ids. No card field and no card data,
// ever: the reader takes the card (docs/pci.md).

import { supabase } from './supabase';
import { PosError } from './posWalkup';
import type { QuestionDef } from './checkoutQuestions';
import type { PrintTicket } from '../../supabase/functions/_shared/print/tickets.ts';
import { saveKioskCredential, type KioskCredential } from './kiosk';

export interface KioskTier {
  tier_id: string;
  name: string;
  description: string | null;
  price_cents: number;
  price_source: 'door' | 'step' | 'base';
  tax: { rate_percent: number; price_includes_tax: boolean } | null;
  unit_total_cents: number;
  /** null = no limit. */
  remaining: number | null;
}

export interface KioskScreen {
  kiosk: { session_id: string; device_id: string; device_name: string | null; printer: boolean; expires_at: string };
  event: { id: string; name: string; starts_at: string | null; venue_name: string | null; currency: string };
  tiers: KioskTier[];
  questions: QuestionDef[];
  max_per_order: number;
  reader: { label: string | null; ready: boolean };
  card: { on: boolean; available: boolean; message: string };
}

/** A kiosk's own sale, as the screen may see it. */
export interface KioskOrder {
  id: string;
  status: 'pending' | 'paid' | 'void' | 'refunded';
  currency: string;
  total_cents: number;
  tier_name: string | null;
  quantity: number | null;
  ticket_count: number;
}

export interface KioskProgress {
  state: 'waiting' | 'succeeded' | 'declined' | 'canceled' | 'refunded';
  order_id: string;
  decline_code?: string | null;
}

export interface KioskExit {
  ok: boolean;
  ended?: boolean;
  error?: 'wrong-pin' | 'locked' | 'rate';
  attempts_left?: number;
  retry_after_seconds?: number;
}

const FRIENDLY: Record<string, string> = {
  'kiosk-ended': 'This kiosk has been switched off.',
  kiosk_unavailable: 'This kiosk is unavailable right now. Please buy at the box office.',
  'sold-out': 'Sold out.',
  'max-per-order': 'That is more tickets than one order allows.',
  'questions-required': 'Please answer the required questions.',
  expired: 'That took too long and the tickets were released. Please start again.',
  'no-reader': "This kiosk's card reader isn't ready. Please buy at the box office.",
  'kiosk-too-late': 'Please ask the staff for these tickets.',
  'handed-over': 'These tickets were already sent.',
  card_service: "The card reader didn't answer. Please try again.",
};

export function kioskErrorText(e: unknown): string {
  if (e instanceof PosError) return (e.code && FRIENDLY[e.code]) || e.message;
  return e instanceof Error ? e.message : 'Something went wrong.';
}

async function kiosk<T>(token: string, body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke('exos-pos', { body: { ...body, kiosk_token: token } });
  if (error) {
    let payload: { error?: string; message?: string } | null = null;
    const ctx = (error as { context?: Response }).context;
    try {
      payload = await ctx?.json();
    } catch {
      /* not JSON */
    }
    throw new PosError(payload?.message || payload?.error || (error as Error).message || 'Request failed',
      payload?.error ?? null, ctx?.status ?? 0);
  }
  return (data as { data: T }).data;
}

export const kioskScreen = (token: string) => kiosk<KioskScreen>(token, { action: 'kiosk_state' });
export const kioskBegin = (token: string, input: { tierId: string; quantity: number; orderKey: string; answers?: unknown }) =>
  kiosk<KioskOrder>(token, { action: 'kiosk_begin', tier_id: input.tierId, quantity: input.quantity, order_key: input.orderKey,
    answers: input.answers });
export const kioskCharge = (token: string, orderId: string) =>
  kiosk<{ order_id: string; state: 'waiting' | 'succeeded' }>(token, { action: 'kiosk_charge', order_id: orderId });
export const kioskStatus = (token: string, orderId: string) => kiosk<KioskProgress>(token, { action: 'kiosk_status', order_id: orderId });
export const kioskCancel = (token: string, orderId: string) => kiosk<KioskProgress>(token, { action: 'kiosk_cancel', order_id: orderId });
export async function kioskCodes(token: string, orderId: string): Promise<PrintTicket[]> {
  const d = await kiosk<{ tickets?: PrintTicket[] }>(token, { action: 'kiosk_codes', order_id: orderId });
  return Array.isArray(d?.tickets) ? d.tickets : [];
}
export const kioskEmail = (token: string, orderId: string, email: string) =>
  kiosk<{ emailed: number }>(token, { action: 'kiosk_email', order_id: orderId, email });
export const kioskExit = (token: string, pin: string) => kiosk<KioskExit>(token, { action: 'kiosk_exit', pin });

// ── Setup (owner / manager, signed in) ──────────────────────────────────────

export interface KioskDevice {
  id: string;
  name: string;
  event_id: string | null;
  kiosk: { event_id: string; reader_device_id: string | null; printer: boolean; pin_set_at: string } | null;
  live: { id: string; started_at: string; expires_at: string } | null;
}

/** The org's register devices with their kiosk flag and live session (RLS: owner / manager). */
export async function listKioskDevices(orgId: string): Promise<KioskDevice[]> {
  const [{ data: devs, error: e1 }, { data: ks, error: e2 }, { data: ss, error: e3 }] = await Promise.all([
    supabase.from('exos_pos_devices').select('id, name, event_id').eq('org_id', orgId).in('kind', ['register', 'other'])
      .eq('status', 'active').order('name'),
    supabase.from('exos_pos_kiosks').select('device_id, event_id, reader_device_id, printer, pin_set_at').eq('org_id', orgId),
    supabase.from('exos_pos_kiosk_sessions').select('id, device_id, started_at, expires_at').eq('org_id', orgId).is('ended_at', null),
  ]);
  const err = e1 || e2 || e3;
  if (err) throw new PosError(err.message, null, 0);
  const now = Date.now();
  return ((devs ?? []) as { id: string; name: string; event_id: string | null }[]).map((d) => {
    const k = ((ks ?? []) as { device_id: string; event_id: string; reader_device_id: string | null; printer: boolean; pin_set_at: string }[])
      .find((x) => x.device_id === d.id);
    const s = ((ss ?? []) as { id: string; device_id: string; started_at: string; expires_at: string }[])
      .find((x) => x.device_id === d.id && new Date(x.expires_at).getTime() > now);
    return { ...d, kiosk: k ? { event_id: k.event_id, reader_device_id: k.reader_device_id, printer: k.printer, pin_set_at: k.pin_set_at } : null,
      live: s ? { id: s.id, started_at: s.started_at, expires_at: s.expires_at } : null };
  });
}

/** A new register device for this screen (owner / manager; RLS). */
export async function addKioskDevice(orgId: string, name: string): Promise<string> {
  const { data, error } = await supabase.from('exos_pos_devices')
    .insert({ org_id: orgId, name: name.trim().slice(0, 80) || 'Kiosk', kind: 'register', status: 'active' }).select('id').single();
  if (error) throw new PosError(error.message, null, 0);
  return (data as { id: string }).id;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new PosError(error.message, (error as { hint?: string }).hint ?? null, 0);
  return data as T;
}

/** Mark a device as this event's kiosk (pin: 6 to 12 digits; empty keeps the current one). */
export const configureKiosk = (input: { deviceId: string; eventId: string; readerId: string | null; pin: string; printer: boolean }) =>
  rpc<{ kiosk: boolean }>('exos_pos_kiosk_configure', {
    p_device: input.deviceId, p_event: input.eventId, p_reader: input.readerId, p_pin: input.pin || null, p_printer: input.printer,
  });
export const turnOffKiosk = (deviceId: string) => rpc<{ kiosk: boolean }>('exos_pos_kiosk_configure', { p_device: deviceId, p_event: null });
export const endKioskSession = (deviceId: string) => rpc<{ ended: boolean }>('exos_pos_kiosk_end', { p_device: deviceId });

/**
 * Start kiosk mode on THIS screen: keep the credential, then sign the member
 * out of this browser (only here), so the screen holds no staff session.
 */
export async function startKioskHere(deviceId: string): Promise<KioskCredential> {
  const r = await rpc<{ token: string; session_id: string; device_id: string; event_id: string }>('exos_pos_kiosk_enter', { p_device: deviceId });
  const cred: KioskCredential = { token: r.token, session_id: r.session_id, device_id: r.device_id, event_id: r.event_id };
  saveKioskCredential(localStorage, cred);
  await supabase.auth.signOut({ scope: 'local' });
  return cred;
}

export const KIOSK_PIN_RULE = '6 to 12 digits, not one digit repeated or a run like 123456';
