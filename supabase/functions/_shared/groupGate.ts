// Group pay (review 2026-11-09, mig 20261110110000): exos-checkout's gate in
// front of a group seat's claim. A seat link works without an account, so
// without a limit one guest could open Stripe Checkout Sessions on it without
// end. Order, before any Stripe call:
//   1. rate limits (exos_rate_hit, per minute): per seat (or cover) and
//      network, and per seat across networks;
//   2. the claim (exos_group_claim), which refuses the same buyer's re-claim
//      while their claim is under 2 minutes old (XG429, DETAIL = the order's
//      session id when one is attached and pending);
//   3. on XG429: a SIGNED-IN buyer's page that is still open is handed back
//      (its url, or client_secret for the embed) instead of a new one; a guest
//      gets a 429 (security review: anyone holding the seat link who knows the
//      guest's email could otherwise fetch that open page).
// Pure apart from the injected calls, so the Deno test checks the order.

// Group pay v2 is paused (operator 2026-11-09, mig 20261111120000): a body
// with group_seat or group_cover is refused with 403 group_pay_off unless
// EXOS_GROUP_PAY=on (unset = off). exos-checkout checks this right after it
// parses the body: before the rate gate, any DB claim or any Stripe call. With
// the env on, the SQL switch (exos_platform_settings group_pay_enabled, off by
// default) still answers XGOFF from exos_group_checkout_ctx / exos_group_claim,
// which maps to the same 403.
export const GROUP_PAY_OFF = { error: "Group pay isn't available", reason: "group_pay_off" } as const;

/** EXOS_GROUP_PAY: on only when exactly "on" (any case, trimmed); unset is off. */
export function groupPayEnvOn(v: string | null | undefined): boolean {
  return typeof v === "string" && v.trim().toLowerCase() === "on";
}

/** The 403 for a group body while group pay is off; null to go on. */
export function groupPayOffGate(
  p: { group_seat?: unknown; group_cover?: unknown } | null | undefined,
  env: string | null | undefined,
): { status: 403; body: Record<string, unknown> } | null {
  if (!p || typeof p !== "object") return null;
  if (p.group_seat === undefined && p.group_cover === undefined) return null;
  if (groupPayEnvOn(env)) return null;
  return { status: 403, body: { ...GROUP_PAY_OFF } };
}

export const GROUP_CLAIM_PER_NETWORK = 5;
export const GROUP_CLAIM_PER_SEAT = 10;

export type GroupKey = { seat: string | null; cover: string | null };

/** The rate-limit buckets for one claim (each under exos_rate_hit's 200 characters). */
export function groupClaimBuckets(g: GroupKey, ipHash: string): { bucket: string; limit: number }[] {
  const key = (g.seat ?? g.cover ?? "none").slice(0, 64);
  return [
    { bucket: `group-claim:${key}:${String(ipHash).slice(0, 100)}`, limit: GROUP_CLAIM_PER_NETWORK },
    { bucket: `group-seat:${key}`, limit: GROUP_CLAIM_PER_SEAT },
  ];
}

export interface GateDeps {
  /** exos_rate_hit: true while under the limit. */
  rateHit(bucket: string, limit: number): Promise<boolean>;
  /** exos_group_claim: the hold id, or the error. */
  claim(): Promise<{ data: unknown; error: { code?: string; message?: string; details?: string | null } | null }>;
  /** The Stripe session behind an open order (stripe.checkout.sessions.retrieve). */
  openSession(id: string): Promise<{ status?: string | null; url?: string | null; client_secret?: string | null } | null>;
  /** exos-checkout's reason for a group error code. */
  reason(code: unknown): string;
}

export type GateResult =
  | { hold: string }
  | { status: number; body: Record<string, unknown> };

export async function gateGroupClaim(g: GroupKey, ipHash: string, deps: GateDeps, opts: { embedded?: boolean; signedIn?: boolean } = {}): Promise<GateResult> {
  for (const b of groupClaimBuckets(g, ipHash)) {
    let ok = false;
    try {
      ok = await deps.rateHit(b.bucket, b.limit);
    } catch {
      // Fail closed: no limit check, no checkout.
      return { status: 503, body: { error: "could not check this seat, try again", reason: "group_rate_check" } };
    }
    if (!ok) {
      return { status: 429, body: { error: "too many tries for this seat: wait a minute and try again", reason: "group_rate_limited" } };
    }
  }
  const { data, error } = await deps.claim();
  if (!error && typeof data === "string" && data) return { hold: data };
  if (error?.code === "XG429") {
    const sid = typeof error.details === "string" && /^cs_[A-Za-z0-9_]{1,250}$/.test(error.details) ? error.details : null;
    // Only to the proven owner: a signed-in buyer (the claim matched their uid).
    if (sid && opts.signedIn) {
      try {
        const cs = await deps.openSession(sid);
        if (cs?.status === "open") {
          if (opts.embedded && cs.client_secret) return { status: 200, body: { client_secret: cs.client_secret, session_id: sid, reused: true } };
          if (!opts.embedded && cs.url) return { status: 200, body: { url: cs.url, session_id: sid, reused: true } };
        }
      } catch {
        // Fall through to the 429: the buyer tries again in a moment.
      }
    }
    return {
      status: 429,
      body: { error: error.message || "your checkout for this seat is already open", reason: "seat_checkout_open" },
    };
  }
  // The SQL switch went off between the context read and the claim.
  if (error?.code === "XGOFF") return { status: 403, body: { ...GROUP_PAY_OFF } };
  return {
    status: 409,
    body: { error: error?.message || "not enough tickets available", reason: deps.reason(error?.code) },
  };
}
