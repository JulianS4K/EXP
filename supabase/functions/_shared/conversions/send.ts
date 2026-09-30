// The send side of exos-conversions-drain: pick the platform's builder, check
// the host, send with a timeout, and sort the answer into the outbox result
// (exos_conversions_mark: sent / failed / retry). Pure apart from the
// injected fetch, so vitest drives it with a stub.

import {
  ALLOWED_HOSTS, type BuildContext, type BuildResult, type ConversionRow, type Credential,
  type PlannedRequest, type Platform, redactRequest,
} from "./common.ts";
import { buildMeta } from "./meta.ts";
import { buildTikTok } from "./tiktok.ts";
import { buildGa4 } from "./ga4.ts";
import { buildReddit } from "./reddit.ts";
import { buildSnap } from "./snap.ts";
import { buildGoogleAds } from "./googleAds.ts";

const BUILDERS: Record<Platform, (row: ConversionRow, cred: Credential, ctx: BuildContext) => BuildResult> = {
  meta: buildMeta,
  tiktok: buildTikTok,
  ga4: buildGa4,
  reddit: buildReddit,
  snap: buildSnap,
  google_ads: buildGoogleAds,
};

/**
 * Platforms whose request is built and stored but not sent. Google Ads needs
 * the Exos Google OAuth client (GOOGLE_OAUTH_CLIENT_ID / _SECRET) to turn the
 * org's refresh token into an access token; without it, it stays planned only.
 */
export function plannedOnly(platform: Platform, opts: { googleOAuthConfigured?: boolean } = {}): boolean {
  return platform === "google_ads" && !opts.googleOAuthConfigured;
}

export function buildConversionRequest(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  const b = BUILDERS[row.platform];
  if (!b) return { ok: false, skip: `unknown platform ${String(row.platform)}` };
  const res = b(row, cred, ctx);
  if (res.ok) {
    let host = "";
    try { host = new URL(res.request.url).hostname; } catch { /* invalid url */ }
    if (!ALLOWED_HOSTS.has(host) || !res.request.url.startsWith("https://")) {
      return { ok: false, skip: `refused host ${host || "(invalid url)"}` };
    }
  }
  return res;
}

export type SendOutcome =
  | { result: "sent"; status: number }
  | { result: "failed" | "retry"; status: number | null; error: string };

type FetchFn = (url: string, init: RequestInit) => Promise<Response>;

/**
 * POST the request. 2xx = sent; 408 / 425 / 429 / 5xx / network errors =
 * retry; any other 4xx = failed (a bad payload or token won't fix itself).
 * The error text is the status plus at most 300 chars of the response,
 * with the secret removed.
 */
export async function sendConversion(
  req: PlannedRequest,
  secret: string,
  fetchFn: FetchFn,
  timeoutMs = 8000,
): Promise<SendOutcome> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetchFn(req.url, {
      method: req.method,
      headers: { "user-agent": "Exos-Conversions/1.0", ...req.headers },
      body: JSON.stringify(req.body),
      redirect: "manual",
      signal: ctrl.signal,
    });
    const status = res.status;
    if (status >= 200 && status < 300) {
      await res.body?.cancel();
      return { result: "sent", status };
    }
    let text = "";
    try { text = (await res.text()).slice(0, 300); } catch { /* no body */ }
    const error = scrubSecret(`http ${status}${text ? `: ${text}` : ""}`, secret);
    const retry = status === 408 || status === 425 || status === 429 || status >= 500;
    return { result: retry ? "retry" : "failed", status, error };
  } catch (e) {
    const msg = e instanceof Error ? (e.name === "AbortError" ? "timeout" : e.message) : "fetch failed";
    return { result: "retry", status: null, error: scrubSecret(msg, secret) };
  } finally {
    clearTimeout(timer);
  }
}

export function scrubSecret(s: string, secret: string): string {
  if (!secret || secret.length < 4) return s;
  return s.split(secret).join("[redacted]").split(encodeURIComponent(secret)).join("[redacted]");
}

export { redactRequest };
