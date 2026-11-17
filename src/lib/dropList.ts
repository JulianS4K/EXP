// Drop list ("Notify me when tickets go on sale", mig 20261118100000;
// docs/fans.md "Drop list"). Pure helpers (sale state, consent words, the
// browser token, CSV rows) plus thin RPC wrappers. The SQL is the gate for
// everything: who may join, the constant guest answer, roles and limits.

import { supabase } from './supabase';
import type { Attribution } from './attribution';
import type { CsvCell } from './csv';

/** Where an event's ticket sale stands for the page's call to action. */
export type SaleState = 'not_yet' | 'on_sale' | 'sold_out' | 'closed';

export interface SaleTier {
  visibility?: string | null;
  capacity?: number | null;
  sold?: number | null;
  salesStart?: { toMillis: () => number } | null;
}

/**
 * The same rule as _exos_drop_open_at: the public, sellable ticket types
 * (capacity > 0). None: closed. One with no start or a start in the past:
 * on sale (sold out when every on-sale type is). All starting later:
 * not yet, which is when the page offers the drop list. Sold out keeps the
 * existing waitlist.
 */
export function saleState(tiers: SaleTier[] | null | undefined, now = Date.now()): SaleState {
  const pub = (tiers ?? []).filter((t) => (t.visibility ?? 'public') === 'public' && Number(t.capacity ?? 0) > 0);
  if (pub.length === 0) return 'closed';
  const open = pub.filter((t) => !t.salesStart || t.salesStart.toMillis() <= now);
  if (open.length === 0) return 'not_yet';
  return open.every((t) => Number(t.sold ?? 0) >= Number(t.capacity ?? 0)) ? 'sold_out' : 'on_sale';
}

/** The earliest public on-sale time while the state is not_yet. */
export function onSaleAt(tiers: SaleTier[] | null | undefined): Date | null {
  const starts = (tiers ?? [])
    .filter((t) => (t.visibility ?? 'public') === 'public' && Number(t.capacity ?? 0) > 0 && t.salesStart)
    .map((t) => t.salesStart!.toMillis());
  return starts.length ? new Date(Math.min(...starts)) : null;
}

/** Only the promoter code and UTM tags travel with a signup (first touch). */
export function dropSource(a: Attribution | null | undefined): Record<string, string> | null {
  if (!a) return null;
  const out: Record<string, string> = {};
  for (const k of ['promoter', 'utm_source', 'utm_medium', 'utm_campaign'] as const) {
    const v = a[k];
    if (typeof v === 'string' && v) out[k] = v;
  }
  return Object.keys(out).length ? out : null;
}

const TOKEN_RE = /^[0-9a-f]{64}$/;

/** A 64-hex token from a mail link (?t=), or null. */
export function linkToken(search: string): string | null {
  const t = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search).get('t');
  return t && TOKEN_RE.test(t) ? t : null;
}

/** This browser's 256-bit token for the event (kept for the visit): the code
 *  in the confirm mail only works from the browser that signed up. */
export function browserToken(eventId: string, rand: (n: number) => Uint8Array = randomBytes): string {
  const key = `exos_drop_bt:${eventId}`;
  try {
    const kept = sessionStorage.getItem(key);
    if (kept && TOKEN_RE.test(kept)) return kept;
  } catch { /* storage blocked: a fresh token per call still works for this page */ }
  const t = [...rand(32)].map((b) => b.toString(16).padStart(2, '0')).join('');
  try { sessionStorage.setItem(key, t); } catch { /* non-fatal */ }
  return t;
}

function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return b;
}

/** A 6-digit code as typed ("123 456" → "123456"), or null. */
export function cleanCode(raw: string): string | null {
  const c = raw.replace(/\s+/g, '');
  return /^[0-9]{6}$/.test(c) ? c : null;
}

export interface DropStatus {
  open: boolean;
  onSaleAt: Date | null;
  listPresale: boolean;
  /** Signed in only: their own signup. */
  joined: boolean;
  sms: boolean;
  phoneHint: string | null;
  /** A number waiting for the code texted to it (nothing consented yet). */
  smsPending: boolean;
  pendingHint: string | null;
  /** The exact words the signup stores (from SQL), while open. */
  emailConsentText: string | null;
  smsConsentText: string | null;
}

export function parseStatus(d: any): DropStatus {
  return {
    open: d?.open === true,
    onSaleAt: d?.on_sale_at ? new Date(d.on_sale_at) : null,
    listPresale: d?.list_presale === true,
    joined: d?.joined === true,
    sms: d?.sms === true,
    phoneHint: typeof d?.phone_hint === 'string' ? d.phone_hint : null,
    smsPending: d?.sms_pending === true,
    pendingHint: typeof d?.pending_hint === 'string' ? d.pending_hint : null,
    emailConsentText: typeof d?.email_consent_text === 'string' ? d.email_consent_text : null,
    smsConsentText: typeof d?.sms_consent_text === 'string' ? d.sms_consent_text : null,
  };
}

export interface DropSource {
  label: string; promoter: string | null; utmSource: string | null; utmMedium: string | null; utmCampaign: string | null;
  signups: number; confirmed: number;
}
export interface DropPresale {
  status: 'off' | 'set' | 'stale';
  minutes: number | null; tierId: string | null; tierName: string | null; code: string | null;
  opensAt: Date | null; publicOnSaleAt: Date | null;
}
export interface DropSummary {
  open: boolean; onSaleAt: Date | null;
  signups: number; confirmed: number; pending: number; sms: number; left: number; notified: number; textsQueued: number;
  sources: DropSource[]; presale: DropPresale; canManage: boolean;
}

export function parsePresale(p: any): DropPresale {
  const status = p?.status === 'set' || p?.status === 'stale' ? p.status : 'off';
  return {
    status,
    minutes: p?.minutes != null ? Number(p.minutes) : null,
    tierId: p?.tier_id ?? null,
    tierName: p?.tier_name ?? null,
    code: p?.code ?? null,
    opensAt: p?.opens_at ? new Date(p.opens_at) : null,
    publicOnSaleAt: p?.public_on_sale_at ? new Date(p.public_on_sale_at) : null,
  };
}

export function parseSummary(d: any): DropSummary {
  const n = (v: unknown) => Number(v) || 0;
  return {
    open: d?.open === true,
    onSaleAt: d?.on_sale_at ? new Date(d.on_sale_at) : null,
    signups: n(d?.signups), confirmed: n(d?.confirmed), pending: n(d?.pending), sms: n(d?.sms),
    left: n(d?.left), notified: n(d?.notified), textsQueued: n(d?.texts_queued),
    sources: (Array.isArray(d?.sources) ? d.sources : []).map((s: any) => ({
      label: String(s?.label ?? 'direct'), promoter: s?.promoter ?? null, utmSource: s?.utm_source ?? null,
      utmMedium: s?.utm_medium ?? null, utmCampaign: s?.utm_campaign ?? null,
      signups: n(s?.signups), confirmed: n(s?.confirmed),
    })),
    presale: parsePresale(d?.presale),
    canManage: d?.can_manage === true,
  };
}

/** What a source row is called on the tile. */
export function sourceLabel(s: Pick<DropSource, 'promoter' | 'utmSource' | 'utmMedium' | 'utmCampaign'>): string {
  if (s.promoter) return `Promoter ${s.promoter}`;
  if (!s.utmSource) return 'Direct (no tag)';
  return [s.utmSource, s.utmMedium, s.utmCampaign].filter(Boolean).join(' / ');
}

export const DROP_CSV_HEADER = ['email', 'joined_at', 'confirmed_at', 'texts', 'promoter', 'utm_source', 'utm_medium', 'utm_campaign'];

export function dropCsvRows(rows: unknown[]): CsvCell[][] {
  return rows.map((r: any) => [
    r?.email ?? '', r?.joined_at ?? '', r?.confirmed_at ?? '', r?.texts === true ? 'yes' : 'no',
    r?.promoter ?? '', r?.utm_source ?? '', r?.utm_medium ?? '', r?.utm_campaign ?? '',
  ]);
}

const msg = (e: { message?: string }) => new Error((e.message ?? 'Failed.').replace(/^exos_\w+: /, ''));

export async function getDropStatus(eventId: string): Promise<DropStatus> {
  const { data, error } = await supabase.rpc('exos_drop_status', { p_event_id: eventId });
  if (error) throw msg(error);
  return parseStatus(data);
}

/** Guest signup: "check your email" for any address, or "try again" when
 *  the event's own signup limit is full (it says nothing about an address). */
export async function dropSignup(eventId: string, email: string, source: Record<string, string> | null): Promise<'check_email' | 'try_again'> {
  const { data, error } = await supabase.rpc('exos_drop_signup', {
    p_event_id: eventId, p_email: email.trim(), p_browser_token: browserToken(eventId), p_source: source,
  });
  if (error) throw msg(error);
  return data?.status === 'try_again' ? 'try_again' : 'check_email';
}

/** The code texted to the number given at join; texts are on only after it. */
export async function dropVerifySms(eventId: string, code: string): Promise<{ verified: boolean; status: DropStatus }> {
  const { data, error } = await supabase.rpc('exos_drop_verify_sms', { p_event_id: eventId, p_code: code });
  if (error) throw msg(error);
  return { verified: data?.verified === true, status: parseStatus(data) };
}

export async function dropConfirmCode(eventId: string, code: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_drop_confirm_code', {
    p_event_id: eventId, p_browser_token: browserToken(eventId), p_code: code,
  });
  if (error) throw msg(error);
  return data?.ok === true;
}

export async function dropJoin(eventId: string, opts: { sms?: boolean; phone?: string | null; source?: Record<string, string> | null } = {}): Promise<DropStatus> {
  const { data, error } = await supabase.rpc('exos_drop_join', {
    p_event_id: eventId, p_sms: !!opts.sms, p_phone: opts.sms ? opts.phone ?? null : null, p_source: opts.source ?? null,
  });
  if (error) throw msg(error);
  return parseStatus(data);
}

export async function dropLeaveMine(eventId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_drop_leave_mine', { p_event_id: eventId });
  if (error) throw msg(error);
}

export async function dropConfirmLink(token: string): Promise<{ ok: boolean; eventId: string | null; eventName: string | null; orgName: string | null }> {
  const { data, error } = await supabase.rpc('exos_drop_confirm', { p_token: token });
  if (error) throw msg(error);
  return { ok: data?.ok === true, eventId: data?.event_id ?? null, eventName: data?.event_name ?? null, orgName: data?.org_name ?? null };
}

export async function dropLeaveLink(token: string): Promise<{ ok: boolean; eventName: string | null }> {
  const { data, error } = await supabase.rpc('exos_drop_leave', { p_token: token });
  if (error) throw msg(error);
  return { ok: data?.ok === true, eventName: data?.event_name ?? null };
}

export async function getDropSummary(eventId: string): Promise<DropSummary> {
  const { data, error } = await supabase.rpc('exos_drop_list_summary', { p_event_id: eventId });
  if (error) throw msg(error);
  return parseSummary(data);
}

export async function exportDropList(eventId: string): Promise<{ count: number; rows: unknown[] }> {
  const { data, error } = await supabase.rpc('exos_drop_list_export', { p_event_id: eventId });
  if (error) throw msg(error);
  return { count: Number(data?.count) || 0, rows: Array.isArray(data?.rows) ? data.rows : [] };
}

/** minutes 0 turns the list presale off. */
export async function setDropPresale(eventId: string, minutes: number, tierId: string | null): Promise<DropPresale> {
  const { data, error } = await supabase.rpc('exos_drop_list_set_presale', {
    p_event_id: eventId, p_minutes: minutes, p_tier_id: tierId,
  });
  if (error) throw msg(error);
  return parsePresale(data);
}
