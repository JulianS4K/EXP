import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';
import { getCurrentAppUser } from './auth';
import type { ToastOptions } from '../context/ToastContext';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export enum OperationType {
  CREATE = 'create',
  UPDATE = 'update',
  DELETE = 'delete',
  LIST = 'list',
  GET = 'get',
  WRITE = 'write',
}

interface FirestoreErrorInfo {
  error: string;
  operationType: OperationType;
  path: string | null;
  // Captured for diagnostic logging only — never include this in the
  // user-facing toast or anything that gets serialized into a thrown Error.
  authInfo: {
    userId?: string | null;
    emailVerified?: boolean | null;
    isAnonymous?: boolean | null;
  };
}

/**
 * Centralised handler for Firestore failures.
 *
 * Previously this function did `throw new Error(JSON.stringify(errInfo))` with
 * the user's email, uid, and provider data baked into the message. Callers
 * never wrapped that throw in a try/catch, so errors silently rejected the
 * surrounding async function — leaving the UI in a stuck loading state and
 * creating a PII leak risk if the error string ever reached an observer.
 *
 * The new contract:
 *   - Always log the error (with PII fields scoped down to non-sensitive ids)
 *     to the console for diagnostic purposes.
 *   - If a `toast` callback is provided, surface a short, user-friendly
 *     message — never the raw error or any auth fields.
 *   - Return `void`. Do NOT throw. Callers stay in their own catch block and
 *     remain in control of state cleanup, navigation, etc.
 */
export type ToastFn = (opts: ToastOptions) => void;

export function handleFirestoreError(
  error: unknown,
  operationType: OperationType,
  path: string | null,
  toast?: ToastFn,
): void {
  const info: FirestoreErrorInfo = {
    error: rawMessage(error) || String(error),
    authInfo: {
      // Intentionally narrowed — no email, displayName, etc. Sourced from the
      // Supabase current-user holder (lib/auth), the app's auth provider.
      userId: getCurrentAppUser()?.uid,
      emailVerified: getCurrentAppUser()?.emailVerified,
    },
    operationType,
    path,
  };
  console.error('Firestore Error:', info);

  if (toast) {
    const friendly = friendlyMessage(error);
    toast({
      kind: 'error',
      title: 'Something went wrong',
      message: friendly,
    });
  }
}

function friendlyMessage(error: unknown): string {
  const msg = rawMessage(error);
  // Surface a couple of common failure modes in plain English.
  if (/permission|insufficient|row-level security/i.test(msg)) {
    return "You don't have permission to do that. Try signing in again.";
  }
  if (/unavailable|network|offline|Failed to fetch/i.test(msg)) {
    return 'Connection problem. Please check your internet and try again.';
  }
  return errMessage(error, 'Could not complete the request. Please try again.');
}

// Supabase / PostgREST errors are plain objects ({ message, code, details }),
// not `Error`s, so `err instanceof Error ? err.message : …` dropped every
// server reason (slug taken, org limits, invite refusals).
function rawMessage(e: unknown): string {
  if (typeof e === 'string') return e;
  if (e && typeof e === 'object' && typeof (e as { message?: unknown }).message === 'string') {
    return (e as { message: string }).message;
  }
  return '';
}

/** A unique violation on the org handle (exos_orgs.slug). */
export function isOrgHandleTaken(e: unknown): boolean {
  const x = (e && typeof e === 'object' ? e : {}) as { code?: string; message?: string; details?: string };
  const text = `${x.message ?? ''} ${x.details ?? ''}`;
  return x.code === '23505' && /exos_orgs_slug|\(slug\)/i.test(text) && !/exos_events/i.test(text);
}

/**
 * The message to show for a failed call: the server's own reason (RPC prefix
 * like "exos_create_org: " dropped), a few codes in plain words, else `fallback`.
 */
export function errMessage(e: unknown, fallback = 'Something went wrong. Please try again.'): string {
  if (isOrgHandleTaken(e)) return 'That handle is taken. Try a different one.';
  const code = e && typeof e === 'object' ? (e as { code?: string }).code : undefined;
  if (code === '42501') return "You don't have permission to do that.";
  const msg = rawMessage(e).trim().replace(/^exos_[a-z0-9_]+:\s*/i, '');
  if (!msg || /^\[object /.test(msg)) return fallback;
  if (/non-2xx|FunctionsHttpError/i.test(msg)) return fallback;
  if (/Failed to fetch|NetworkError/i.test(msg)) return 'Connection problem. Please check your internet and try again.';
  if (code === '23505') return 'That is already in use. Try a different one.';
  return msg.charAt(0).toUpperCase() + msg.slice(1);
}

/**
 * Format a number as currency in the given ISO 4217 code. Defaults to
 * USD when the caller doesn't supply one — matches the legacy behavior
 * for any code path that hasn't been threaded through with a currency
 * yet (e.g., dashboards summarising mixed-currency events).
 *
 * Falls back gracefully if Intl rejects an unknown code.
 */
export function formatCurrency(amount: number, currency = 'USD') {
  const code = (currency || 'USD').toUpperCase();
  try {
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: code,
    }).format(amount);
  } catch {
    // Bad code — render the number with the literal code suffix.
    return `${amount.toFixed(2)} ${code}`;
  }
}

/**
 * Build an absolute URL to a client route, honoring the Vite base path.
 *
 * The SPA is served under `/bridge/` today (vite `base` + `<BrowserRouter
 * basename>`), and moves to root after the beta DNS split. `BASE_URL` tracks
 * that ('/bridge/' now, '/' later), so links built here resolve in BOTH
 * topologies. Building `${origin}/event/x` directly omits the base and 404s
 * under the current /bridge deployment (there is no bare /event route on the
 * server — only /bridge/* hosts the SPA).
 *
 * @param path route path, leading slash optional (e.g. `event/123` or `/claim/x`)
 */
export function publicUrl(path: string): string {
  const origin = typeof window !== 'undefined' ? window.location.origin : '';
  const base = ((import.meta as { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/');
  const cleanBase = base.endsWith('/') ? base.slice(0, -1) : base; // '/bridge' | ''
  const cleanPath = path.startsWith('/') ? path : `/${path}`;
  return `${origin}${cleanBase}${cleanPath}`;
}

export function generateBarcodeContent(ticketId: string, ownerId: string, secret?: string) {
  // Rotating barcode: ticketId + ownerId + current 30s bucket + secret.
  // The 30s bucket means a screenshotted QR stops scanning after at most
  // 30 seconds; the secret is rotated on transfer so an old owner can't
  // forge the new owner's barcode.
  const timestamp = Math.floor(Date.now() / 30000);
  return `T-${ticketId}:${ownerId}:${timestamp}${secret ? ':' + secret : ''}`;
}

// NOTE: `getStripe` lives in `./stripe`. Import it directly from there in
// the views that need it (currently only EventDetails). We deliberately do
// NOT re-export it here — a re-export is a side-effect import in ES modules,
// which would defeat the chunk split for `formatCurrency` consumers.
