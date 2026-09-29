// Calls to the exos-wallet edge function (docs/wallet.md → Routes). Plain
// fetch rather than supabase.functions.invoke: the Apple answer is binary
// (.pkpass), and the buttons need the HTTP status (503 = not configured).
// Pure rules (platforms, the probe cache, eligibility) are in ./walletButtons.

import { supabase } from './supabase';
import {
  availabilityFromStatus,
  isGoogleSaveUrl,
  PROBE_TICKET_ID,
  readWalletAvailability,
  walletErrorMessage,
  writeWalletAvailability,
  type WalletAvailability,
  type WalletKind,
} from './walletButtons';

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

function walletBase(): string {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  return url ? `${url}/functions/v1/exos-wallet` : '';
}

function sessionStore(): Storage | null {
  try {
    return typeof sessionStorage === 'undefined' ? null : sessionStorage;
  } catch {
    return null;
  }
}

export class WalletUnavailableError extends Error {
  constructor() {
    super('wallet not configured');
    this.name = 'WalletUnavailableError';
  }
}

async function postPass(ticketId: string, kind: WalletKind): Promise<Response> {
  const base = walletBase();
  if (!base) throw new WalletUnavailableError();
  const { data } = await supabase.auth.getSession();
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  return fetch(`${base}/pass`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(anon ? { apikey: anon } : {}),
      Authorization: `Bearer ${data.session?.access_token ?? anon}`,
    },
    body: JSON.stringify({ ticket_id: ticketId, kind }),
  });
}

/** The cached answers for this browser session. */
export function cachedWalletAvailability(): WalletAvailability {
  return readWalletAvailability(sessionStore());
}

export function markWalletUnavailable(kind: WalletKind): WalletAvailability {
  return writeWalletAvailability(sessionStore(), kind, false);
}

// One probe per kind per page load, however many buttons ask at once.
const inflight = new Map<WalletKind, Promise<boolean | null>>();

/**
 * Is this wallet set up? Asks exos-wallet for the nil ticket's pass: 503 when
 * the wallet isn't configured, 403 otherwise (no pass is made). The answer is
 * kept for the session; a network failure isn't cached (null).
 */
export function probeWallet(kind: WalletKind): Promise<boolean | null> {
  const cached = cachedWalletAvailability()[kind];
  if (cached !== undefined) return Promise.resolve(cached);
  let p = inflight.get(kind);
  if (!p) {
    p = (async () => {
      try {
        const res = await postPass(PROBE_TICKET_ID, kind);
        const ok = availabilityFromStatus(res.status);
        if (ok !== null) writeWalletAvailability(sessionStore(), kind, ok);
        return ok;
      } catch (e) {
        if (e instanceof WalletUnavailableError) {
          writeWalletAvailability(sessionStore(), kind, false);
          return false;
        }
        return null;
      } finally {
        inflight.delete(kind);
      }
    })();
    inflight.set(kind, p);
  }
  return p;
}

async function failure(res: Response): Promise<Error> {
  if (res.status === 503) {
    return new WalletUnavailableError();
  }
  let reason: string | undefined;
  try {
    reason = ((await res.json()) as { error?: string })?.error;
  } catch {
    /* not JSON */
  }
  return new Error(walletErrorMessage(reason));
}

/** The signed .pkpass for a ticket the caller holds. */
export async function fetchApplePass(ticketId: string): Promise<Blob> {
  const res = await postPass(ticketId, 'apple');
  if (!res.ok) throw await failure(res);
  const bytes = await res.arrayBuffer();
  return new Blob([bytes], { type: 'application/vnd.apple.pkpass' });
}

/** Google's "save to wallet" link for a ticket the caller holds. */
export async function fetchGoogleSaveUrl(ticketId: string): Promise<string> {
  const res = await postPass(ticketId, 'google');
  if (!res.ok) throw await failure(res);
  const body = (await res.json().catch(() => null)) as { save_url?: unknown } | null;
  if (!isGoogleSaveUrl(body?.save_url)) throw new Error(walletErrorMessage(null));
  return body!.save_url as string;
}
