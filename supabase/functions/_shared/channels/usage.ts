// Platform usage counters for the limits (limits.ts): per org, platform,
// scope (a Luma calendar, an account) and metric, over rolling windows
// (exos_channel_usage, mig 20261121162400). Live usage and planned (dry-run)
// usage are kept apart: a plan is counted once per identical request
// (dedupe), so a dry run repeated every pass doesn't grow, and the preview
// reads "would use N of M". Pure: the database counter takes an rpc
// function, so tests use the memory one.

import type { UsageReading } from "./limits.ts";

export interface UsageKey { platform: string; scopeKey: string; metric: string; windowSeconds: number }

export interface ReserveInput extends UsageKey {
  n: number;
  /** null: no threshold (just count). */
  threshold: number | null;
  live: boolean;
  /** Planned rows: one per identical request (hex). */
  dedupe?: string;
}

export interface ReserveResult {
  /** Live: spent (it fit). Planned: it would fit next to the live usage. */
  ok: boolean;
  id?: string;
  liveUsed: number;
  plannedUsed: number;
  remaining: number | null;
}

export interface UsageCounter {
  read(key: UsageKey): Promise<UsageReading>;
  reserve(input: ReserveInput): Promise<ReserveResult>;
  /** Give back a live reservation the platform refused outright (nothing was used). */
  release(id: string): Promise<void>;
}

type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;

/** The database counter (service role: exos_channel_usage_*). */
export function rpcUsageCounter(rpc: Rpc, orgId: string): UsageCounter {
  return {
    async read(k) {
      const { data, error } = await rpc("exos_channel_usage_read", {
        p_org_id: orgId, p_platform: k.platform, p_scope_key: k.scopeKey, p_metric: k.metric, p_window_seconds: k.windowSeconds,
      });
      if (error) throw new Error("usage read failed");
      const d = (data ?? {}) as { live?: number; planned?: number };
      return { live: Number(d.live ?? 0), planned: Number(d.planned ?? 0) };
    },
    async reserve(i) {
      const { data, error } = await rpc("exos_channel_usage_reserve", {
        p_org_id: orgId, p_platform: i.platform, p_scope_key: i.scopeKey, p_metric: i.metric, p_n: i.n,
        p_window_seconds: i.windowSeconds, p_threshold: i.threshold, p_live: i.live, p_dedupe: i.dedupe ?? null,
      });
      if (error) throw new Error("usage reserve failed");
      const d = (data ?? {}) as { ok?: boolean; id?: string; live_used?: number; planned_used?: number; remaining?: number | null };
      return { ok: d.ok === true, id: d.id, liveUsed: Number(d.live_used ?? 0), plannedUsed: Number(d.planned_used ?? 0), remaining: d.remaining ?? null };
    },
    async release(id) {
      await rpc("exos_channel_usage_release", { p_org_id: orgId, p_id: id });
    },
  };
}

interface Row { id: string; key: string; n: number; live: boolean; dedupe?: string; at: number }

/** In memory, with an injectable clock: the tests and dry-run tools. Same rules as the SQL. */
export function memoryUsageCounter(now: () => number = Date.now): UsageCounter & { rows: Row[] } {
  const rows: Row[] = [];
  let seq = 0;
  const k = (u: UsageKey) => `${u.platform}|${u.scopeKey}|${u.metric}`;
  const sum = (u: UsageKey, live: boolean) => {
    const from = u.windowSeconds > 0 ? now() - u.windowSeconds * 1000 : Number.NEGATIVE_INFINITY;
    return rows.filter((r) => r.key === k(u) && r.live === live && r.at > from).reduce((a, r) => a + r.n, 0);
  };
  return {
    rows,
    async read(u) {
      return { live: sum(u, true), planned: sum(u, false) };
    },
    async reserve(i) {
      if (!Number.isInteger(i.n) || i.n < 1) throw new Error("usage: n must be a positive integer");
      const live = sum(i, true);
      const fits = i.threshold === null || live + i.n <= i.threshold;
      const remaining = i.threshold === null ? null : Math.max(i.threshold - live, 0);
      if (i.live) {
        if (!fits) return { ok: false, liveUsed: live, plannedUsed: sum(i, false), remaining };
        const id = `u${++seq}`;
        rows.push({ id, key: k(i), n: i.n, live: true, at: now() });
        return { ok: true, id, liveUsed: live + i.n, plannedUsed: sum(i, false), remaining: i.threshold === null ? null : Math.max(i.threshold - live - i.n, 0) };
      }
      const same = i.dedupe ? rows.find((r) => !r.live && r.key === k(i) && r.dedupe === i.dedupe) : undefined;
      let id: string;
      if (same) {
        same.n = i.n;
        same.at = now();
        id = same.id;
      } else {
        id = `u${++seq}`;
        rows.push({ id, key: k(i), n: i.n, live: false, dedupe: i.dedupe, at: now() });
      }
      return { ok: fits, id, liveUsed: live, plannedUsed: sum(i, false), remaining };
    },
    async release(id) {
      const at = rows.findIndex((r) => r.id === id && r.live);
      if (at >= 0) rows.splice(at, 1);
    },
  };
}
