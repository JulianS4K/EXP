// Audit steps for the channel core (exos_channel_audit, mig 20261121162400):
// every request GatedHttp plans or sends is one step, with the secrets
// already redacted (the SQL writer scrubs secret-named keys again). A sink
// decides where steps go: memory (tests, a pass's plan) or the database
// (exos_channel_audit_record, batched, written by flush()).

import type { LimitHit } from "./limits.ts";

export type HttpMethod = "GET" | "HEAD" | "POST" | "PUT" | "PATCH" | "DELETE";

export interface AuditStep {
  channel: string;
  op: string;
  method: HttpMethod;
  /** Path (and query) on the channel's base; credentials never appear here. */
  path: string;
  /** Sent to the platform (true) or planned only (false). */
  live: boolean;
  /** What was (or would have been) sent: headers and body, redacted. */
  request?: { headers?: Record<string, string>; body?: unknown };
  /** A summary of the answer (status, ids, sizes), never the full body. */
  response?: Record<string, unknown>;
  status?: number;
  ok?: boolean;
  error?: string;
  warnings?: Array<Pick<LimitHit, "ruleId" | "action" | "reason"> & { remaining?: number; would?: number }>;
  event_id?: string;
  at: string;
}

export interface AuditSink {
  record(step: AuditStep): void;
  /** Write what was recorded (the database sink); a no-op elsewhere. */
  flush?(): Promise<void>;
}

/** Keeps every step (tests; a pass that returns its plan). */
export function memoryAuditSink(): AuditSink & { steps: AuditStep[] } {
  const steps: AuditStep[] = [];
  return { steps, record: (s) => { steps.push(s); } };
}

type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;

/**
 * The database sink. Writes (planned or sent) always; reads only with
 * `reads: true` (a credential test, say), so a sync's page reads don't fill
 * the table. Batched: flush() writes at most 50 steps a call. A failed write
 * is logged and dropped: the audit never fails the pass.
 */
export function rpcAuditSink(rpc: Rpc, orgId: string, opts: { reads?: boolean; log?: (msg: string) => void } = {}): AuditSink & { pending: AuditStep[] } {
  const pending: AuditStep[] = [];
  const isRead = (m: HttpMethod) => m === "GET" || m === "HEAD";
  return {
    pending,
    record(s) {
      if (isRead(s.method) && !opts.reads) return;
      pending.push(s);
    },
    async flush() {
      while (pending.length) {
        const batch = pending.splice(0, 50);
        const { error } = await rpc("exos_channel_audit_record", { p_org_id: orgId, p_steps: batch });
        if (error) (opts.log ?? console.error)("channel audit: write failed; steps dropped");
      }
    },
  };
}

/** Fans one step out to several sinks (a pass's own plan + the database). */
export function teeSink(...sinks: AuditSink[]): AuditSink {
  return {
    record: (s) => sinks.forEach((k) => k.record(s)),
    flush: async () => { for (const k of sinks) await k.flush?.(); },
  };
}
