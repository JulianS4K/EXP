// Door network helpers (pure, unit-tested): a hard deadline for requests, and
// telling "the server answered with an error" apart from "the server could not
// be reached". Only the second may fall back to the offline rules; a server
// answer (not authorized, bad input) must never turn into an offline admit.

/** Door check-in requests give up after this and decide on the cached list. */
export const DOOR_REQUEST_TIMEOUT_MS = 4_000;

export class DoorTimeoutError extends Error {
  constructor(ms: number) {
    super(`door request timed out after ${ms} ms`);
    this.name = 'DoorTimeoutError';
  }
}

/** Run `fn` with an AbortSignal that fires after `ms`, and stop waiting at
 *  `ms` even if the call ignores the signal. */
export async function withDeadline<T>(fn: (signal: AbortSignal) => Promise<T>, ms: number = DOOR_REQUEST_TIMEOUT_MS): Promise<T> {
  const ctrl = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      ctrl.abort();
      reject(new DoorTimeoutError(ms));
    }, ms);
  });
  try {
    return await Promise.race([fn(ctrl.signal), deadline]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/** True when the error is an answer from Postgres / PostgREST (a SQLSTATE such
 *  as 42501, or a PGRST code), so the server was reached. Fetch failures,
 *  aborts and timeouts come back with an empty or missing code. */
export function isServerAnswer(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  if (err instanceof DoorTimeoutError) return false;
  const code = (err as { code?: unknown }).code;
  if (typeof code !== 'string') return false;
  return /^[0-9A-Z]{5}$/.test(code) || /^PGRST\d+$/.test(code);
}

/** The RPC isn't on this database yet (PostgREST schema cache miss, or
 *  Postgres "function does not exist"): use the older call. */
export function isMissingRpc(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  const code = (err as { code?: unknown }).code;
  return code === 'PGRST202' || code === '42883';
}
