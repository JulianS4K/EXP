// GatedHttp: the one HTTP client a channel adapter talks to its platform
// through (channel core, mig 20261121162400; docs/security.md "GatedHttp").
// Pure apart from the injected fetch: no Deno or Node APIs beyond Web Crypto,
// so the Deno tests and vitest import it.
//
// ONE DECISION, live or dry run (decideLive): a write goes out only when the
// org's switch is on (exos_org_integrations.writes_enabled, passed in) AND
// the operator's EXOS_<ID>_WRITES=on AND the method + path is on the
// adapter's allowlist. Every flag defaults off. A write that is not on the
// allowlist is refused (thrown) whatever the switches; an allowed write with
// a switch off is a dry run: nothing is sent, the exact payload (secrets
// redacted) is recorded, and a stand-in answer comes back. writesLive() is
// the existing gate from model.ts, reused.
//
// Reads (GET / HEAD) always go out and are retried on 429 / 5xx / a network
// failure under _shared/retry.ts (Retry-After honoured up to its limit). A
// write is sent once, unless its allowlist rule says it is idempotent.
//
// Every request is one audit step (audit.ts) with secrets redacted: header
// values that carry a credential, and every value in `secrets` wherever it
// appears. Credentials go in headers only: a URL (path or query) holding a
// secret value, or a query parameter named like one, is refused before
// anything is sent.
//
// LIMITS (limits.ts). Before a write, planned or live, the platform's rules
// are checked against the facts and the usage counters (usage.ts): a block
// refuses with the reason (LIMIT_BLOCKED, nothing sent), a cap refuses a
// request bigger than what is left (LIMIT_CAPPED, `limit.maxUnits` says how
// much fits: the adapter chunks with chunkToBudget), a warning goes through
// and is recorded on the step. A counted request spends the counter when
// live (an atomic reserve; given back on a 4xx) and is recorded as planned
// usage, once per identical request, in a dry run.

import { CHANNEL_RETRY, nextWait, realSleep, type RetryPolicy } from "../retry.ts";
import { writesLive } from "./model.ts";
import type { AuditSink, AuditStep, HttpMethod } from "./audit.ts";
import { evaluateLimits, rulesFor, thresholdFor, windowSeconds, type LimitFacts, type LimitVerdict, type UsageReadings } from "./limits.ts";
import type { UsageCounter } from "./usage.ts";

export type { HttpMethod } from "./audit.ts";
export type WriteMethod = Exclude<HttpMethod, "GET" | "HEAD">;

export interface WriteRule {
  method: WriteMethod;
  /** Matched against the path without its query string. */
  path: RegExp;
  /** A PUT / DELETE the platform treats as idempotent may be retried. */
  idempotent?: boolean;
}

export interface GatedHttpOptions {
  /** The adapter id: picks EXOS_<ID>_WRITES and the limits table. */
  channel: string;
  /** https origin (and optional prefix) every path is appended to. */
  base: string;
  fetch: typeof fetch;
  env: (name: string) => string | undefined | null;
  /** The org's switch for this channel (exos_org_integrations.writes_enabled). */
  orgWritesEnabled: unknown;
  /** The adapter's write allowlist. Empty: a read-only adapter. */
  writes: readonly WriteRule[];
  /** Sent with every request: credentials go here, never in a URL. */
  headers?: Record<string, string>;
  /** Values redacted from every audit step, and refused in any URL. */
  secrets?: readonly (string | null | undefined)[];
  audit: AuditSink;
  /** The answer a dry-run write gets back. */
  standIn?: (method: WriteMethod, path: string, body: unknown) => unknown;
  retry?: RetryPolicy;
  timeoutMs?: number;
  limits?: { platform?: string; counter?: UsageCounter; facts?: LimitFacts; scopeKey?: string };
  eventId?: string;
  now?: () => Date;
}

export interface RequestOptions {
  body?: unknown;
  op?: string;
  headers?: Record<string, string>;
  /** A counted request (limits.ts metric): n units of it. */
  usage?: { metric: string; n: number; scopeKey?: string };
  facts?: LimitFacts;
}

export interface GatedResponse {
  ok: boolean;
  status: number;
  body: any;
  error?: string;
  /** Sent to the platform. */
  live: boolean;
  /** A dry-run write: nothing was sent, `body` is the stand-in. */
  planned: boolean;
  limit?: LimitVerdict;
  headers?: Headers;
}

export interface GatedHttp {
  readonly channel: string;
  /** Writes on the allowlist would go out (both switches on). */
  readonly writesLive: boolean;
  decide(method: HttpMethod, path: string): LiveDecision;
  request(method: HttpMethod, path: string, opts?: RequestOptions): Promise<GatedResponse>;
  get(path: string, opts?: RequestOptions): Promise<GatedResponse>;
  /** A fetch for read helpers written against fetch (pretix.ts, ...): GET / HEAD on `base` only. */
  asFetch(): typeof fetch;
}

export class GatedHttpRefused extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GatedHttpRefused";
  }
}

const READS: ReadonlySet<string> = new Set(["GET", "HEAD"]);
const METHODS: ReadonlySet<string> = new Set(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]);
export const isRead = (m: string): boolean => READS.has(m.toUpperCase());

/** EXOS_<ID>_WRITES: "luma" -> EXOS_LUMA_WRITES, "google_events" -> EXOS_GOOGLE_EVENTS_WRITES. */
export function writeFlagName(channel: string): string {
  return `EXOS_${channel.toUpperCase().replace(/[^A-Z0-9]+/g, "_")}_WRITES`;
}

export interface LiveDecision {
  read: boolean;
  /** On the adapter's allowlist (reads always are). */
  allowed: boolean;
  /** This request goes out. */
  live: boolean;
  flag: string;
  /** Why a write stays a dry run (or is refused). */
  reasons: string[];
}

/**
 * THE decision. A read: always live. A write: live only when the org's
 * switch AND the operator's flag are on AND the method + path is allowed.
 */
export function decideLive(
  o: Pick<GatedHttpOptions, "channel" | "env" | "orgWritesEnabled" | "writes">, method: HttpMethod, path: string,
): LiveDecision {
  const flag = writeFlagName(o.channel);
  const m = method.toUpperCase();
  if (READS.has(m)) return { read: true, allowed: true, live: true, flag, reasons: [] };
  const bare = path.split("?")[0];
  const allowed = o.writes.some((r) => r.method === m && r.path.test(bare));
  const org = o.orgWritesEnabled === true;
  const env = o.env(flag) ?? null;
  const reasons: string[] = [];
  if (!allowed) reasons.push(`${m} ${bare} is not on the ${o.channel} allowlist`);
  if (!org) reasons.push("the organization's switch is off");
  if (env !== "on") reasons.push(`${flag} is not on`);
  return { read: false, allowed, live: allowed && writesLive(org, env), flag, reasons };
}

// ---- redaction ---------------------------------------------------------------

const SECRET_HEADER = /^(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|apikey|x-auth-token|x-access-token|x-shared-key)$/i;
/** Body keys whose values are never recorded (the SQL writer applies the same rule). */
export const SECRET_KEY = /(authorization|cookie|token|secret|password|passwd|api[_-]?key|client[_-]?secret|signature|credential)/i;
const SECRET_QUERY = /^(api[_-]?key|apikey|key|token|access[_-]?token|auth|secret|client[_-]?secret|password|signature|sig)$/i;
export const REDACTED = "[redacted]";

const usable = (secrets: readonly (string | null | undefined)[] | undefined): string[] =>
  (secrets ?? []).filter((s): s is string => typeof s === "string" && s.length >= 4);

function scrubString(s: string, secrets: string[]): string {
  let out = s;
  for (const sec of secrets) {
    out = out.split(sec).join(REDACTED);
    const enc = encodeURIComponent(sec);
    if (enc !== sec) out = out.split(enc).join(REDACTED);
  }
  return out;
}

/** A deep copy with secret values and secret-named keys redacted. */
export function redact(value: unknown, secrets: readonly (string | null | undefined)[] = [], depth = 0): unknown {
  const secs = usable(secrets);
  if (value === null || value === undefined) return value;
  if (depth > 12) return "[too deep]";
  if (typeof value === "string") return scrubString(value, secs);
  if (Array.isArray(value)) return value.map((v) => redact(v, secs, depth + 1));
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = SECRET_KEY.test(k) ? REDACTED : redact(v, secs, depth + 1);
    }
    return out;
  }
  return value;
}

export function redactHeaders(h: Record<string, string>, secrets: readonly (string | null | undefined)[] = []): Record<string, string> {
  const secs = usable(secrets);
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(h)) {
    out[k] = SECRET_HEADER.test(k) || secs.some((s) => v.includes(s)) ? REDACTED : v;
  }
  return out;
}

/**
 * Throws unless the URL carries no credential: no secret value (raw or
 * URL-encoded) anywhere in it, and no query parameter named like one.
 */
export function assertNoSecretsInUrl(url: string, secrets: readonly (string | null | undefined)[] = []): void {
  for (const s of usable(secrets)) {
    if (url.includes(s) || url.includes(encodeURIComponent(s))) {
      throw new GatedHttpRefused("gatedHttp: a credential in a URL; credentials go in headers");
    }
  }
  const q = url.indexOf("?");
  if (q >= 0) {
    for (const part of url.slice(q + 1).split("&")) {
      const name = decodeURIComponent(part.split("=")[0] ?? "");
      if (SECRET_QUERY.test(name)) throw new GatedHttpRefused(`gatedHttp: query parameter "${name.slice(0, 40)}" looks like a credential; send it in a header`);
    }
  }
}

function checkPath(path: string): void {
  if (typeof path !== "string" || !path.startsWith("/") || path.includes("..") || path.includes("//")
      || path.includes("\\") || /[\s@#]/.test(path.split("?")[0])) {
    throw new GatedHttpRefused("gatedHttp: bad path");
  }
}

/** Status, size and a few ids of an answer; never the body itself. */
export function summarize(status: number, body: unknown, bytes: number): Record<string, unknown> {
  const out: Record<string, unknown> = { status, bytes };
  if (Array.isArray(body)) out.items = body.length;
  else if (body && typeof body === "object") {
    const o = body as Record<string, unknown>;
    out.keys = Object.keys(o).slice(0, 12);
    for (const k of ["id", "api_id", "event_id"]) {
      if (typeof o[k] === "string" || typeof o[k] === "number") out[k] = String(o[k]).slice(0, 80);
    }
  }
  return out;
}

async function hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, "0")).join("");
}

// ---- the client --------------------------------------------------------------

export function createGatedHttp(o: GatedHttpOptions): GatedHttp {
  if (!/^https:\/\/[^/?#@\s]+(\/[^?#@\s]*)?$/.test(o.base)) throw new GatedHttpRefused("gatedHttp: the base must be an https URL");
  const base = o.base.replace(/\/+$/, "");
  const secrets = usable(o.secrets);
  const policy = o.retry ?? CHANNEL_RETRY;
  const sleep = policy.sleep ?? realSleep;
  const now = o.now ?? (() => new Date());
  const baseHeaders = o.headers ?? {};
  const platform = o.limits?.platform ?? o.channel;
  assertNoSecretsInUrl(base, secrets);

  const record = (s: Omit<AuditStep, "channel" | "at" | "event_id">) =>
    o.audit.record({ channel: o.channel, at: now().toISOString(), ...(o.eventId ? { event_id: o.eventId } : {}), ...s });

  const once = async (method: HttpMethod, path: string, headers: Record<string, string>, body: unknown) => {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), o.timeoutMs ?? 15_000);
    try {
      const hasBody = body !== undefined && !READS.has(method);
      const res = await o.fetch(base + path, {
        method,
        headers: { Accept: "application/json", ...(hasBody ? { "Content-Type": "application/json" } : {}), ...headers },
        body: hasBody ? JSON.stringify(body) : undefined,
        signal: ctrl.signal,
        redirect: "error",
      });
      const text = method === "HEAD" ? "" : await res.text().catch(() => "");
      let parsed: unknown = null;
      try { parsed = text ? JSON.parse(text) : null; } catch { parsed = null; }
      const error = res.ok ? undefined : `HTTP_${res.status}`;
      return { ok: res.ok, status: res.status, body: parsed as any, error, bytes: text.length, retryAfter: res.headers.get("retry-after"), headers: res.headers };
    } catch (err) {
      // A network failure is fetch's TypeError; anything else (an SSRF
      // guard's refusal, _shared/ssrf.ts) is final and never retried.
      const error = (err as Error)?.name === "AbortError" ? "TIMEOUT" : err instanceof TypeError ? "NETWORK" : "REFUSED";
      return { ok: false, status: 0, body: null, error, bytes: 0, retryAfter: null, headers: undefined };
    } finally {
      clearTimeout(timer);
    }
  };

  // The usage readings the platform's counted rules need for this request.
  const readUsage = async (metric: string, scopeKey: string): Promise<UsageReadings> => {
    const out: UsageReadings = {};
    const counter = o.limits?.counter;
    if (!counter) return out;
    for (const r of rulesFor(platform)) {
      if (r.kind !== "usage" || r.metric !== metric || out[metric]) continue;
      out[metric] = await counter.read({ platform, scopeKey, metric, windowSeconds: windowSeconds(r.window) });
    }
    return out;
  };

  const request = async (methodIn: HttpMethod, path: string, ro: RequestOptions = {}): Promise<GatedResponse> => {
    const method = String(methodIn).toUpperCase() as HttpMethod;
    if (!METHODS.has(method)) throw new GatedHttpRefused(`gatedHttp: method ${method} not supported`);
    checkPath(path);
    const headers = { ...baseHeaders, ...(ro.headers ?? {}) };
    assertNoSecretsInUrl(base + path, secrets);
    const d = decideLive(o, method, path);
    const op = ro.op ?? (d.read ? "read" : "write");
    const reqRecord = { headers: redactHeaders(headers, secrets), ...(ro.body !== undefined ? { body: redact(ro.body, secrets) } : {}) };

    if (d.read) {
      for (let attempt = 1; ; attempt++) {
        const r = await once(method, path, headers, undefined);
        const wait = r.ok || r.error === "REFUSED" ? null : nextWait(attempt, r.status, r.error, r.retryAfter, policy);
        if (wait === null) {
          record({ op, method, path, live: true, request: reqRecord, response: summarize(r.status, r.body, r.bytes),
                   status: r.status, ok: r.ok, ...(r.error ? { error: r.error } : {}) });
          return { ok: r.ok, status: r.status, body: r.body, error: r.error, live: true, planned: false, headers: r.headers };
        }
        await sleep(wait);
      }
    }

    if (!d.allowed) {
      record({ op, method, path, live: false, request: reqRecord, ok: false, error: "NOT_ALLOWED" });
      throw new GatedHttpRefused(`gatedHttp: ${method} ${path.split("?")[0]} is not an allowed ${o.channel} write`);
    }

    // Limits, before anything is planned or sent.
    const scopeKey = ro.usage?.scopeKey ?? o.limits?.scopeKey ?? "";
    const facts = { ...(o.limits?.facts ?? {}), ...(ro.facts ?? {}) };
    const usage = ro.usage ? await readUsage(ro.usage.metric, scopeKey) : {};
    const verdict = evaluateLimits(platform, facts, usage, ro.usage ?? null);
    const warnings = [...verdict.warnings, ...verdict.caps].map((h) => ({
      ruleId: h.ruleId, action: h.action, reason: h.reason,
      ...(h.remaining !== undefined ? { remaining: h.remaining } : {}), ...(h.would !== undefined ? { would: h.would } : {}),
    }));
    const warn = warnings.length ? { warnings } : {};
    if (verdict.blocks.length) {
      record({ op, method, path, live: false, request: reqRecord, ok: false, error: "LIMIT_BLOCKED",
               warnings: verdict.blocks.map((h) => ({ ruleId: h.ruleId, action: h.action, reason: h.reason })) });
      return { ok: false, status: 0, body: null, error: "LIMIT_BLOCKED", live: false, planned: false, limit: verdict };
    }
    if (!verdict.allowed) {
      record({ op, method, path, live: false, request: reqRecord, ok: false, error: "LIMIT_CAPPED", ...warn });
      return { ok: false, status: 0, body: null, error: "LIMIT_CAPPED", live: false, planned: false, limit: verdict };
    }
    const counted = ro.usage && o.limits?.counter ? ro.usage : null;
    const rule = counted ? rulesFor(platform).find((r) => r.kind === "usage" && r.metric === counted.metric) : undefined;
    const reserveArgs = counted ? {
      platform, scopeKey, metric: counted.metric, n: counted.n, windowSeconds: windowSeconds(rule?.window),
      threshold: rule && rule.action !== "warn" ? thresholdFor(rule, facts) : null,
    } : null;

    if (!d.live) {
      if (reserveArgs) {
        const dedupe = await hex(`${method} ${path} ${JSON.stringify(ro.body ?? null)}`);
        await o.limits!.counter!.reserve({ ...reserveArgs, live: false, dedupe });
      }
      const standIn = o.standIn ? o.standIn(method as WriteMethod, path.split("?")[0], ro.body) : { id: "dry-run", dry_run: true };
      record({ op, method, path, live: false, request: reqRecord, response: { stand_in: true, reasons: d.reasons }, ok: true, ...warn });
      return { ok: true, status: 200, body: standIn, live: false, planned: true, limit: verdict };
    }

    let reservation: string | undefined;
    if (reserveArgs) {
      const r = await o.limits!.counter!.reserve({ ...reserveArgs, live: true });
      if (!r.ok) {
        record({ op, method, path, live: false, request: reqRecord, ok: false, error: "LIMIT_CAPPED", ...warn });
        return { ok: false, status: 0, body: null, error: "LIMIT_CAPPED", live: false, planned: false,
                 limit: { ...verdict, allowed: false, maxUnits: r.remaining ?? 0 } };
      }
      reservation = r.id;
    }
    const idempotent = o.writes.some((w) => w.method === method && w.path.test(path.split("?")[0]) && w.idempotent === true);
    for (let attempt = 1; ; attempt++) {
      const r = await once(method, path, headers, ro.body);
      const wait = r.ok || !idempotent || r.error === "REFUSED" ? null : nextWait(attempt, r.status, r.error, r.retryAfter, policy);
      if (wait === null) {
        if (!r.ok && reservation && r.status >= 400 && r.status < 500) await o.limits!.counter!.release(reservation);
        record({ op, method, path, live: true, request: reqRecord, response: summarize(r.status, r.body, r.bytes),
                 status: r.status, ok: r.ok, ...(r.error ? { error: r.error } : {}), ...warn });
        return { ok: r.ok, status: r.status, body: r.body, error: r.error, live: true, planned: false, limit: verdict, headers: r.headers };
      }
      await sleep(wait);
    }
  };

  const gated: GatedHttp = {
    channel: o.channel,
    writesLive: writesLive(o.orgWritesEnabled, o.env(writeFlagName(o.channel)) ?? null),
    decide: (method, path) => decideLive(o, method, path),
    request,
    get: (path, ro) => request("GET", path, ro),
    asFetch() {
      return (async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        const method = (init?.method ?? "GET").toUpperCase();
        if (!READS.has(method)) throw new GatedHttpRefused("gatedHttp: asFetch is for reads; use request() for a write");
        if (!(url === base || url.startsWith(base + "/") || url.startsWith(base + "?"))) {
          throw new GatedHttpRefused("gatedHttp: asFetch only reaches the channel's base");
        }
        const path = url.slice(base.length) || "/";
        const h: Record<string, string> = {};
        new Headers(init?.headers ?? {}).forEach((v, k) => { h[k] = v; });
        const r = await request(method as HttpMethod, path, { headers: h, op: "read" });
        return new Response(r.body === null || r.body === undefined ? null : JSON.stringify(r.body), {
          status: r.status || 599,
          headers: { "content-type": r.headers?.get("content-type") ?? "application/json" },
        });
      }) as typeof fetch;
    },
  };
  return gated;
}
