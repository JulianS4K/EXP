// RPC wrappers for commission methods (mig 20261104190000). The functions
// enforce roles: owner / manager change settings, finance reads; the split
// switch is the owner's.

import { supabase } from './supabase';
import { normalizeBalances, type CommissionMethod } from './commissionMethods';

export interface CommissionEventRow {
  eventId: string; name: string; startsAt: string | null; method: CommissionMethod | null;
  lockedMethod: CommissionMethod | null; sold: boolean; effective: CommissionMethod;
}
export interface CommissionSettings {
  configured: boolean; defaultMethod: CommissionMethod; holdbackDays: number; splitAtSaleEnabled: boolean;
  nettingAlertDays: number; clawbackTransfersEnabled: boolean; organizerAccount: boolean;
  events: CommissionEventRow[];
  promoters: { promoterId: string; name: string; code: string; method: CommissionMethod | null; accountReady: boolean }[];
}

/** null before the migration (the panel then hides). */
export async function getCommissionSettings(orgId: string): Promise<CommissionSettings | null> {
  const { data, error } = await supabase.rpc('exos_get_commission_settings', { p_org_id: orgId });
  if (error || !data) return null;
  const d = data as any;
  return {
    configured: !!d.configured, defaultMethod: d.default_method, holdbackDays: Number(d.holdback_days ?? 3),
    splitAtSaleEnabled: !!d.split_at_sale_enabled, nettingAlertDays: Number(d.netting_alert_days ?? 30),
    clawbackTransfersEnabled: !!d.clawback_transfers_enabled, organizerAccount: !!d.organizer_account,
    events: (d.events ?? []).map((e: any) => ({
      eventId: e.event_id, name: e.name, startsAt: e.starts_at ?? null, method: e.method ?? null,
      lockedMethod: e.locked_method ?? null, sold: !!e.sold, effective: e.effective,
    })),
    promoters: (d.promoters ?? []).map((p: any) => ({
      promoterId: p.promoter_id, name: p.name, code: p.code, method: p.method ?? null, accountReady: !!p.account_ready,
    })),
  };
}

export async function saveCommissionSettings(orgId: string, s: {
  defaultMethod: CommissionMethod; holdbackDays: number; nettingAlertDays?: number; splitAtSaleEnabled?: boolean;
}): Promise<void> {
  const { error } = await supabase.rpc('exos_set_commission_settings', {
    p_org_id: orgId, p_default_method: s.defaultMethod, p_holdback_days: s.holdbackDays,
    p_netting_alert_days: s.nettingAlertDays ?? null, p_split_at_sale_enabled: s.splitAtSaleEnabled ?? null,
  });
  if (error) throw error;
}

export async function setEventCommissionMethod(eventId: string, method: CommissionMethod | null, futureSalesOnly = false): Promise<void> {
  const { error } = await supabase.rpc('exos_set_event_commission_method', {
    p_event_id: eventId, p_method: method, p_future_sales_only: futureSalesOnly,
  });
  if (error) throw error;
}

export async function setPromoterCommissionMethod(promoterId: string, method: CommissionMethod | null): Promise<void> {
  const { error } = await supabase.rpc('exos_set_promoter_commission_method', { p_promoter_id: promoterId, p_method: method });
  if (error) throw error;
}

export interface CommissionTransferRow {
  id: string; kind: string; promoter: string | null; currency: string; grossCents: number; nettedCents: number;
  amountCents: number; status: string; error: string | null; alert: string | null; createdAt: string;
}

export async function getCommissionBalances(orgId: string) {
  const { data, error } = await supabase.rpc('exos_commission_balances', { p_org_id: orgId });
  if (error) return null;
  const transfers: CommissionTransferRow[] = (((data as any)?.transfers ?? []) as any[]).map((t) => ({
    id: t.id, kind: t.kind, promoter: t.promoter ?? null, currency: t.currency, grossCents: t.gross_cents,
    nettedCents: t.netted_cents, amountCents: t.amount_cents, status: t.status, error: t.error ?? null,
    alert: t.alert ?? null, createdAt: t.created_at,
  }));
  return { ...normalizeBalances(data), transfers };
}

/** Per unpaid sale: can it be settled here, and is it past the holdback? (empty before the migration) */
export async function listCommissionPayable(promoterId: string): Promise<Map<string, { payable: boolean; settleHere: boolean; payableAt: string | null; method: CommissionMethod }>> {
  const { data, error } = await supabase.rpc('exos_commission_payable', { p_promoter_id: promoterId });
  if (error) return new Map();
  return new Map(((data ?? []) as any[]).map((r) => [r.id as string, {
    payable: !!r.payable, settleHere: !!r.settle_here, payableAt: r.payable_at ?? null, method: r.method,
  }]));
}

async function payoutsFn(path: string, body: Record<string, unknown>): Promise<any> {
  const { data, error } = await supabase.functions.invoke(`exos-promoter-payouts/${path}`, { body });
  if (error) {
    const ctx = (error as { context?: Response }).context;
    const parsed = ctx && typeof ctx.json === 'function' ? await ctx.json().catch(() => null) : null;
    throw new Error(parsed?.error || error.message || 'Something went wrong.');
  }
  return data;
}

/** Owner / manager: plan and send what is due now for this org (or retry one transfer). */
export const runCommissionTransfers = (orgId: string, transferId?: string): Promise<{ planned: number; sent: number; dry_run: number; failed: number }> =>
  payoutsFn('run', { org_id: orgId, ...(transferId ? { transfer_id: transferId } : {}) });
/** Owner / manager: cancel an Exos transfer that never went out. */
export const cancelCommissionTransfer = (transferId: string): Promise<{ status: string }> => payoutsFn('ct-cancel', { transfer_id: transferId });
