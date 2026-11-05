// Proof of email or phone before a guest's tickets are released (mig
// 20261105100000; docs/guest-checkout.md). The paying browser keeps the token
// exos-checkout returned (localStorage, per order); the success page uses it
// to confirm the mailed code, or text a code to a phone instead. Organizers
// see the orders still waiting and can send one to a corrected email.
//
// Where storage is blocked (Instagram / Facebook in-app browsers), the token
// also comes back on the return URL's fragment (#pt=, set by exos-checkout
// for Stripe and PayPal's redirect, and by this file for our own redirects).
// takeProofTokenFromUrl reads it once, keeps it in memory and strips it from
// the address bar. The token alone releases nothing: the emailed (or texted)
// 6-digit code is still needed.

import { supabase } from './supabase';
import {
  asProofLinks, hashWithoutProofToken, normalizeProofCode, parseProofState, proofTokenFromHash,
  type ProofClaimLink, type ProofState, type ProofStatus,
} from '../../supabase/functions/_shared/orderProof.ts';

export {
  normalizeProofCode, parseProofState, proofErrorMessage, withProofFragment, type ProofClaimLink, type ProofState,
  type ProofStatus,
} from '../../supabase/functions/_shared/orderProof.ts';

const KEY = (sessionId: string) => `exos:proof:${sessionId}`;

// This page load's copies, for browsers that refuse storage: per order (from
// exos-checkout's answer), and the one read from the URL fragment (not tied
// to an order id; a wrong one just answers "unknown").
const inMemory = new Map<string, string>();
let fromUrl: string | null = null;

/** Keep the order's browser token (best effort: private windows may refuse). */
export function rememberProofToken(sessionId: string | null | undefined, token: string | null | undefined): void {
  if (!sessionId || !token) return;
  inMemory.set(sessionId, token);
  try { localStorage.setItem(KEY(sessionId), token); } catch { /* storage off: the URL fragment carries it */ }
}

/**
 * The token from the URL fragment (#pt=), if this page load had one. Strips
 * it from the address bar (history.replaceState, the rest of the URL kept) so
 * it isn't bookmarked, shared or read by scripts that load later. Call it
 * before anything reads location (pixels) or navigates away from the URL.
 */
export function takeProofTokenFromUrl(): string | null {
  if (typeof window === 'undefined') return fromUrl;
  const { hash, pathname, search } = window.location;
  const t = proofTokenFromHash(hash);
  if (t) {
    fromUrl = t;
    try {
      window.history.replaceState(window.history.state, '', pathname + search + hashWithoutProofToken(hash));
    } catch { /* the address bar keeps it; harmless without the code */ }
  }
  return fromUrl;
}

export function recallProofToken(sessionId: string | null | undefined): string | null {
  if (!sessionId) return null;
  try {
    const stored = localStorage.getItem(KEY(sessionId));
    if (stored) return stored;
  } catch { /* storage off */ }
  const t = inMemory.get(sessionId) ?? takeProofTokenFromUrl();
  if (t) rememberProofToken(sessionId, t);
  return t;
}

export function forgetProofToken(sessionId: string): void {
  inMemory.delete(sessionId);
  fromUrl = null;
  try { localStorage.removeItem(KEY(sessionId)); } catch { /* ignore */ }
}

/** For tests: drop this page load's in-memory tokens. */
export function _resetProofTokensForTest(): void {
  inMemory.clear();
  fromUrl = null;
}

export interface ProofAnswer extends Partial<ProofState> {
  ok: boolean;
  error?: string;
  attempts_left?: number;
  to?: string;
}

function parseAnswer(d: unknown): ProofAnswer {
  const r = (d && typeof d === 'object' ? d : {}) as Record<string, unknown>;
  return {
    ok: r.ok === true, error: typeof r.error === 'string' ? r.error : undefined,
    attempts_left: r.attempts_left === undefined ? undefined : Number(r.attempts_left),
    to: typeof r.to === 'string' ? r.to : undefined,
    status: typeof r.status === 'string' ? r.status as ProofStatus : undefined,
    attached: r.attached === true, tickets: asProofLinks(r.tickets),
  };
}

export async function getProofStatus(sessionId: string, token: string): Promise<ProofState> {
  const { data, error } = await supabase.rpc('exos_order_proof_status', { p_session_id: sessionId, p_token: token });
  if (error) throw error;
  return parseProofState(data);
}

export async function sendProofCode(sessionId: string, token: string, channel: 'email' | 'sms', phone?: string): Promise<ProofAnswer> {
  const { data, error } = await supabase.rpc('exos_order_proof_send', {
    p_session_id: sessionId, p_token: token, p_channel: channel, p_phone: phone ?? null,
  });
  if (error) throw error;
  return parseAnswer(data);
}

export async function verifyProofCode(sessionId: string, token: string, code: string): Promise<ProofAnswer> {
  const c = normalizeProofCode(code);
  if (!c) return { ok: false, error: 'bad_code' };
  const { data, error } = await supabase.rpc('exos_order_proof_verify', { p_session_id: sessionId, p_token: token, p_code: c });
  if (error) throw error;
  return parseAnswer(data);
}

// --- Organizer (owner / manager) -----------------------------------------------

export interface OrderProofRow {
  sessionId: string;
  email: string;
  originalEmail: string;
  status: ProofStatus;
  provenVia: string | null;
  expiresAt: string;
  createdAt: string;
  tickets: number;
  resends: number;
}

export async function listOrderProofs(eventId: string): Promise<OrderProofRow[]> {
  const { data, error } = await supabase.rpc('exos_org_order_proofs', { p_event_id: eventId });
  if (error) throw error;
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    sessionId: String(r.session_id), email: String(r.email ?? ''), originalEmail: String(r.original_email ?? ''),
    status: String(r.status ?? 'pending') as ProofStatus, provenVia: (r.proven_via as string) ?? null,
    expiresAt: String(r.expires_at ?? ''), createdAt: String(r.created_at ?? ''),
    tickets: Number(r.tickets ?? 0) || 0, resends: Number(r.resends ?? 0) || 0,
  }));
}

/** Send an order still waiting for proof to a corrected email: the old claim
 *  links die and new ones go to the new address. */
export async function resendOrderProof(sessionId: string, email: string): Promise<void> {
  const { error } = await supabase.rpc('exos_order_proof_resend', { p_session_id: sessionId, p_email: email.trim() });
  if (error) throw new Error(String(error.message ?? 'Could not resend.').replace(/^exos_order_proof_resend: /, ''));
}
