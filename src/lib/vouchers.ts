// Vouchers (pretix-style access tokens) — distinct from discount codes.
//
// Buyers validate a code (checkVoucher) before checkout; a valid voucher may
// unlock a sold-out tier, pin a price or take a percent / amount off (promo
// codes, mig 20260928060000). Organizers mint/list/delete codes.
// Codes are org-secret (staff RLS); the buyer path only ever gets a yes/no + the
// grant, never the code list.

import { supabase } from './supabase';
import { mapTier } from './events';
import type { Event } from '../types';

export interface VoucherCheck {
  valid: boolean;
  voucherId: string | null;
  restrictTierId: string | null;
  canBypass: boolean;
  overridePrice: number | null;
  /** Percent off the scheduled price (0-100 exclusive), or null. */
  discountPercent: number | null;
  /** Amount off each ticket, or null. */
  discountAmount: number | null;
  reason: string | null;
}

export interface Voucher {
  id: string;
  code: string;
  tierId: string | null;
  maxUses: number;
  usedCount: number;
  bypassCapacity: boolean;
  priceOverride: number | null;
  discountPercent: number | null;
  discountAmount: number | null;
  reservedEmail: string | null;
  validUntil: string | null;
  comment: string | null;
  createdAt: string;
}

/** Buyer-facing validation (no consume). */
export async function checkVoucher(eventId: string, code: string, email?: string | null): Promise<VoucherCheck> {
  const { data, error } = await supabase.rpc('exos_check_voucher', {
    p_event_id: eventId, p_code: code.trim(), p_email: email ?? null,
  });
  if (error) throw error;
  const r = Array.isArray(data) ? data[0] : data;
  const valid = r?.is_valid === true;
  // What a valid code takes off (mig 20260928060000). Before that migration the
  // RPC is missing: no discount, as then.
  let discountPercent: number | null = null;
  let discountAmount: number | null = null;
  if (valid) {
    const { data: d } = await supabase.rpc('exos_voucher_discount', {
      p_event_id: eventId, p_code: code.trim(), p_email: email ?? null,
    });
    const row = Array.isArray(d) ? d[0] : d;
    discountPercent = row?.discount_percent != null ? Number(row.discount_percent) : null;
    discountAmount = row?.discount_amount != null ? Number(row.discount_amount) : null;
  }
  return {
    valid,
    voucherId: r?.voucher_id ?? null,
    restrictTierId: r?.restrict_tier_id ?? null,
    canBypass: r?.can_bypass === true,
    overridePrice: r?.override_price != null ? Number(r.override_price) : null,
    discountPercent,
    discountAmount,
    reason: r?.reason ?? null,
  };
}

/** The hidden tier a valid voucher unlocks (exos_voucher_tier, mig
 *  20260925000000). The public tier list never includes hidden tiers, so the
 *  event page adds this one once the code checks out. Null when the code is
 *  invalid or isn't restricted to a tier. */
export async function getVoucherTier(
  eventId: string, code: string, email?: string | null,
): Promise<NonNullable<Event['ticketTiers']>[number] | null> {
  const { data, error } = await supabase.rpc('exos_voucher_tier', {
    p_event_id: eventId, p_code: code.trim(), p_email: email ?? null,
  });
  if (error) return null;
  const row = Array.isArray(data) ? data[0] : data;
  return row ? mapTier(row) : null;
}

/** Organizer: mint a voucher; returns the generated code. */
export async function issueVoucher(input: {
  eventId: string;
  tierId?: string | null;
  reservedEmail?: string | null;
  bypassCapacity?: boolean;
  priceOverride?: number | null;
  /** Percent off (0-100 exclusive); at most one of priceOverride / discountPercent / discountAmount. */
  discountPercent?: number | null;
  discountAmount?: number | null;
  maxUses?: number;
  validHours?: number | null;
  comment?: string | null;
  /** A code the organizer picks (e.g. PRESALE); random when empty. */
  code?: string | null;
}): Promise<string> {
  const { data, error } = await supabase.rpc('exos_issue_voucher', {
    p_event_id: input.eventId,
    p_tier_id: input.tierId ?? null,
    p_reserved_email: input.reservedEmail ?? null,
    p_bypass_capacity: input.bypassCapacity ?? true,
    p_price_override: input.priceOverride ?? null,
    p_max_uses: input.maxUses ?? 1,
    p_valid_hours: input.validHours ?? null,
    p_comment: input.comment ?? null,
    // Only sent when set (mig 20260925012000 added it).
    ...(input.code?.trim() ? { p_code: input.code.trim() } : {}),
    // Only sent when set (mig 20260928060000 added them).
    ...(input.discountPercent != null ? { p_discount_percent: input.discountPercent } : {}),
    ...(input.discountAmount != null ? { p_discount_amount: input.discountAmount } : {}),
  });
  if (error) throw error;
  return data as string;
}

export async function listVouchers(eventId: string): Promise<Voucher[]> {
  const { data, error } = await supabase
    .from('exos_vouchers').select('*').eq('event_id', eventId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, code: r.code, tierId: r.tier_id, maxUses: r.max_uses, usedCount: r.used_count,
    bypassCapacity: r.bypass_capacity, priceOverride: r.price_override,
    discountPercent: r.discount_percent != null ? Number(r.discount_percent) : null,
    discountAmount: r.discount_amount != null ? Number(r.discount_amount) : null,
    reservedEmail: r.reserved_email,
    validUntil: r.valid_until, comment: r.comment, createdAt: r.created_at,
  }));
}

export async function deleteVoucher(id: string): Promise<void> {
  const { error } = await supabase.from('exos_vouchers').delete().eq('id', id);
  if (error) throw error;
}
