// Event tokens: the calls (mig 20261114110000). Every rule is in SQL (roles,
// org / event scope, balances, rate limits); these are thin wrappers. The pure
// logic (the door's state machine, the offline ledger, the report rows) is in
// ./eventTokens.ts.

import { supabase } from './supabase';
import type { SpendAnswer, TokenBundle, TokenProductDraft, TokenReport } from './eventTokens';

export interface TokenOffer { credits: number; price_cents: number }

export interface TokenProduct {
  id: string;
  event_id: string;
  name: string;
  unit_label: string;
  price_cents: number;
  bundles: TokenBundle[];
  max_per_order: number;
  refundable: boolean;
  grace_hours: number;
  active: boolean;
  rule: string;
  expires_at: string | null;
  offers: TokenOffer[];
}

export interface TokenBalance {
  product_id: string;
  name: string;
  unit_label: string;
  credits: number;
  expires_at: string | null;
  refundable: boolean;
}

export interface MyTicketTokens {
  ticket_id: string;
  event_id: string;
  event_name: string;
  balances: TokenBalance[];
  rules: Record<string, string>;
}

export interface TokenSale {
  order_id: string;
  card_id: string;
  /** The new token code, shown once ("K-…"); null on a top-up or a replay. */
  code: string | null;
  code_last4: string | null;
  credits: number;
  total_cents: number;
  payment: 'cash' | 'comp';
  balance: number;
  replay: boolean;
  rule?: string;
}

export class TokenError extends Error {
  constructor(message: string, public code: string | null, public hint: string | null) {
    super(message);
  }
}

function fail(error: unknown): never {
  const e = error as { message?: string; code?: string; hint?: string };
  throw new TokenError(e?.message || 'Request failed', e?.code ?? null, e?.hint ?? null);
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) fail(error);
  return data as T;
}

/** The event's token products (door staff, owner / manager / finance). [] before the migration. */
export async function listTokenProducts(eventId: string): Promise<TokenProduct[]> {
  const { data, error } = await supabase.rpc('exos_event_token_products', { p_event_id: eventId });
  if (error) {
    const code = (error as { code?: string }).code;
    if (code === 'PGRST202' || code === '42883') return [];
    fail(error);
  }
  return (data ?? []) as TokenProduct[];
}

export const saveTokenProduct = (eventId: string, draft: TokenProductDraft) =>
  rpc<TokenProduct>('exos_event_token_product_save', { p_event_id: eventId, p_product: draft });

export const lookupTokens = (eventId: string, code: string) =>
  rpc<{ ok: boolean; reason?: string; balances?: TokenBalance[]; ticket?: boolean }>('exos_event_token_lookup', { p_event_id: eventId, p_code: code });

export const spendTokens = (input: {
  eventId: string; code: string; productId: string; credits: number; ref: string; offlineAt?: number | null; device?: string | null;
}) => rpc<SpendAnswer>('exos_event_token_spend', {
  p_event_id: input.eventId, p_code: input.code, p_product_id: input.productId, p_credits: input.credits,
  p_client_ref: input.ref, p_offline_at: input.offlineAt != null ? new Date(input.offlineAt).toISOString() : null,
  p_device: input.device ?? null,
});

export const undoTokenSpend = (eventId: string, ledgerId: number, reason: string) =>
  rpc<{ ok: boolean; duplicate: boolean; balance: number }>('exos_event_token_undo', { p_event_id: eventId, p_ledger_id: ledgerId, p_reason: reason });

export const tokenRoster = (eventId: string) => rpc<unknown>('exos_event_token_roster', { p_event_id: eventId });

export const sellTokens = (input: {
  eventId: string; productId: string; offerCredits: number; quantity: number; payment: 'cash' | 'comp'; orderKey: string;
  code?: string | null; compReason?: string | null;
}) => rpc<TokenSale>('exos_event_token_pos_sell', {
  p_event_id: input.eventId, p_product_id: input.productId, p_offer_credits: input.offerCredits, p_quantity: input.quantity,
  p_payment: input.payment, p_order_key: input.orderKey, p_code: input.code ?? null, p_device_id: null, p_drawer_id: null,
  p_comp_reason: input.compReason ?? null,
});

export const tokenReport = (eventId: string) => rpc<TokenReport>('exos_event_token_report', { p_event_id: eventId });

export const expireTokens = (eventId: string) =>
  rpc<{ lots: number; credits: number; cents: number }>('exos_event_token_expire', { p_event_id: eventId });

export interface TokenRefund {
  replay: boolean; lot_id: string; source: 'online' | 'pos' | 'comp'; credits: number; amount_cents: number;
  session_id: string | null; refund_key: string | null; paid_out_id?: string | null;
}

/**
 * Refund a purchase's unused tokens (owner / manager, refundable products). An
 * online purchase is then refunded through the existing partial refund
 * (exos-refund, amount_cents), keyed on the returned refund_key so a retry is
 * one refund; door cash comes back out of the member's drawer in SQL.
 */
export async function refundUnusedTokens(eventId: string, lotId: string, reason: string): Promise<TokenRefund & { stripe?: unknown }> {
  const r = await rpc<TokenRefund>('exos_event_token_refund_unused', { p_event_id: eventId, p_lot_id: lotId, p_reason: reason, p_drawer_id: null });
  if (r.source !== 'online' || !r.session_id || !r.refund_key || r.amount_cents <= 0) return r;
  const { data, error } = await supabase.functions.invoke('exos-refund', {
    body: { action: 'refund', session_id: r.session_id, nonce: r.refund_key, amount_cents: r.amount_cents, reason: 'Unused event tokens' },
  });
  if (error) throw new TokenError('The tokens came off the card, but the refund didn\'t go through yet: try "Refund" again.', null, 'refund-pending');
  return { ...r, stripe: data };
}

export const myEventTokens = async (eventId: string | null): Promise<MyTicketTokens[]> => {
  const { data, error } = await supabase.rpc('exos_my_event_tokens', { p_event_id: eventId });
  if (error) return [];
  return (data ?? []) as MyTicketTokens[];
};
