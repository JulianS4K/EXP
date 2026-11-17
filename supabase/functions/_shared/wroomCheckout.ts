// exos: waiting room (mig 20261118120000), exos-checkout's side of "one turn,
// one order": attach the attempt to the turn (taking over the same buyer's
// earlier Stripe session), and bind the order's session id to it.
// Dependencies are passed in, so the flow is tested with mocks
// (wroomCheckout_test.ts).

export interface RpcError {
  code?: string;
  message: string;
}
export type WroomRpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: RpcError | null }>;

/** What became of a Stripe Checkout session we tried to expire (our own platform account). */
export type StripeEnd = "expired" | "complete" | "open" | "unknown";

export interface AttachDeps {
  rpc: WroomRpc;
  /** Expire the session at Stripe; on an error, retrieve it and say where it stands. */
  expireStripe: (sessionId: string) => Promise<StripeEnd>;
  /** Mark our row expired (pending only): its trigger frees the turn. */
  markExpired: (sessionId: string) => Promise<void>;
  log?: (msg: string) => void;
}

export interface AttachArgs {
  p_event_id: string;
  p_tier_id: string;
  p_token: string | null;
  p_buyer_uid: string | null;
  p_email: string | null;
  p_attempt: string;
}

export type AttachResult =
  | { kind: "ok"; attached: boolean; tookOver?: string }
  | { kind: "refused"; code: "XWR01" | "XWR02" | "XWR03" }
  | { kind: "error"; message: string };

const REFUSALS = new Set(["XWR01", "XWR02", "XWR03"]);

function readAttach(data: unknown): { attached: boolean; takeover: string | null } {
  // Before the jsonb answer (an older migration) attach returned a boolean.
  if (data === true || data === false) return { attached: data, takeover: null };
  const o = (data && typeof data === "object" ? data : {}) as Record<string, unknown>;
  const t = typeof o.takeover === "string" && /^cs_[A-Za-z0-9_]{1,250}$/.test(o.takeover) ? o.takeover : null;
  return { attached: o.attached === true, takeover: t };
}

/**
 * Attach this checkout to the buyer's turn. When the same buyer's earlier
 * Stripe session still holds it, expire that session at Stripe, mark its row
 * expired and attach again (once). A session that is complete, still paying,
 * or can't be reached keeps the turn: XWR02.
 */
export async function wroomAttach(deps: AttachDeps, args: AttachArgs): Promise<AttachResult> {
  let tookOver: string | undefined;
  for (let round = 0; round < 2; round++) {
    const { data, error } = await deps.rpc("exos_wroom_attach", { ...args });
    if (error) {
      if (error.code && REFUSALS.has(error.code)) return { kind: "refused", code: error.code as "XWR01" | "XWR02" | "XWR03" };
      if (error.code === "PGRST202") return { kind: "ok", attached: false };  // not migrated yet
      return { kind: "error", message: error.message };
    }
    const a = readAttach(data);
    if (!a.takeover) return { kind: "ok", attached: a.attached, ...(tookOver ? { tookOver } : {}) };
    if (round > 0) return { kind: "refused", code: "XWR02" };
    const end = await deps.expireStripe(a.takeover);
    if (end !== "expired") {
      deps.log?.(`exos-checkout: waiting room take-over kept ${a.takeover} (${end})`);
      return { kind: "refused", code: "XWR02" };
    }
    await deps.markExpired(a.takeover);
    tookOver = a.takeover;
  }
  return { kind: "refused", code: "XWR02" };
}

/**
 * Bind the order's session id to the attached turn, before its row is
 * written. One retry on an error; false when it didn't bind (the caller
 * stops before taking money).
 */
export async function wroomBindSession(
  rpc: WroomRpc,
  args: { p_event_id: string; p_attempt: string; p_session_id: string; p_buyer_uid: string | null; p_email: string | null },
  log?: (msg: string) => void,
): Promise<boolean> {
  for (let i = 0; i < 2; i++) {
    const { data, error } = await rpc("exos_wroom_bind", { ...args });
    if (!error) return data !== false;
    log?.(`exos-checkout: waiting room bind failed: ${error.message}`);
  }
  return false;
}
