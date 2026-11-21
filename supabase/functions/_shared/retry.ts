// Bounded retries for idempotent reads of an upstream API (Eventbrite, Luma,
// the ticket backends; DICE uses the same backoff). No Deno or Node APIs
// beyond fetch and timers, so vitest imports it too.
//
// Only GET is ever retried. A POST that failed or timed out may still have
// happened on the other side, so it is never sent again from here: the
// caller looks the result up on its next pass instead (exos-channel-sync's
// pending create, mig 20261121100000).

export type Sleep = (ms: number) => Promise<void>;
export const realSleep: Sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export interface RetryPolicy {
  /** Retries after the first try. */
  maxRetries: number;
  /** First backoff (doubles each retry, with jitter). */
  baseMs: number;
  /** The longest wait: a Retry-After above it stops retrying (the next pass picks it up). */
  maxWaitMs: number;
  sleep?: Sleep;
  random?: () => number;
}

/** Channel syncs run inside a 100 s cron budget: two quick retries at most. */
export const CHANNEL_RETRY: RetryPolicy = { maxRetries: 2, baseMs: 500, maxWaitMs: 5_000 };

/** 429, 5xx and a network failure (status 0) are worth another try. A timeout isn't (it already took the budget). */
export function retryableStatus(status: number, error?: string): boolean {
  if (error === "TIMEOUT") return false;
  return status === 429 || status === 0 || (status >= 500 && status <= 599);
}

/** Retry-After in ms (seconds or an HTTP date), or null when absent / unreadable. */
export function retryAfterMs(header: string | null | undefined, now: number = Date.now()): number | null {
  if (!header) return null;
  const h = header.trim();
  if (/^\d+(\.\d+)?$/.test(h)) return Math.round(Number(h) * 1000);
  const at = Date.parse(h);
  return Number.isFinite(at) ? Math.max(at - now, 0) : null;
}

/** Wait before retry `attempt` (1-based): Retry-After when sent (capped at maxMs), else exponential with jitter. */
export function backoffMs(
  attempt: number, retryAfter: string | null, random: () => number = Math.random,
  baseMs = 500, maxMs = 30_000,
): number {
  const ra = retryAfterMs(retryAfter);
  if (ra !== null) return Math.min(ra, maxMs);
  const base = Math.min(baseMs * 2 ** (attempt - 1), maxMs);
  return Math.round(base / 2 + random() * (base / 2));
}

/**
 * How long to wait before retry `attempt` (1-based), or null to stop: not
 * retryable, out of retries, or the server asked for longer than maxWaitMs.
 */
export function nextWait(attempt: number, status: number, error: string | undefined, retryAfter: string | null, p: RetryPolicy): number | null {
  if (!retryableStatus(status, error) || attempt > p.maxRetries) return null;
  const ra = retryAfterMs(retryAfter);
  if (ra !== null && ra > p.maxWaitMs) return null;
  return backoffMs(attempt, retryAfter, p.random ?? Math.random, p.baseMs, p.maxWaitMs);
}

/**
 * A fetch that retries GET (and HEAD) under `policy`; anything else is sent
 * once, as is. Each try is a fresh request (no body to replay). A thrown
 * network error (TypeError) is retried like a 5xx; anything else is rethrown.
 */
export function retryingGetFetch(f: typeof fetch, policy: RetryPolicy = CHANNEL_RETRY): typeof fetch {
  const sleep = policy.sleep ?? realSleep;
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
    if (method !== "GET" && method !== "HEAD") return f(input, init);
    for (let attempt = 1; ; attempt++) {
      let res: Response | null = null;
      try {
        res = await f(input, init);
      } catch (err) {
        // Only a network failure (fetch's TypeError) is retried: not an abort,
        // not a guard's refusal (_shared/ssrf.ts guardedFetch).
        if (!(err instanceof TypeError)) throw err;
        const wait = nextWait(attempt, 0, "NETWORK", null, policy);
        if (wait === null) throw err;
        await sleep(wait);
        continue;
      }
      const wait = res.ok ? null : nextWait(attempt, res.status, undefined, res.headers.get("retry-after"), policy);
      if (wait === null) return res;
      await res.body?.cancel().catch(() => {});
      await sleep(wait);
    }
  }) as typeof fetch;
}
