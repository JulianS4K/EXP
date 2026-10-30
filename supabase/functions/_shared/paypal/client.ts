// PayPal REST client for the PLATFORM's own PayPal account (operator
// approval 2026-10-30, CLAUDE.md "Upstream ticketing APIs"). The only writes
// allowed are order create, order capture and capture refund. Everything
// else is a read, plus the two non-data POSTs PayPal's API needs: the OAuth
// token and the webhook signature check. Any other POST throws before a
// request is sent (assertAllowed), so nothing here can reach payouts,
// vaulting, invoicing or account settings.
//
// Environment (sandbox unless explicitly live):
//   EXOS_PAYPAL_ENV=live   AND PAYPAL_CLIENT_ID + PAYPAL_CLIENT_SECRET set
//                            -> https://api-m.paypal.com
//   anything else            -> https://api-m.sandbox.paypal.com (with the
//                               sandbox app's keys in the same two secrets)
//   keys missing             -> paypalConfig() is null: PayPal is off.
// PAYPAL_WEBHOOK_ID: the webhook's id in the PayPal app (signature checks).
//
// fetch is injected so tests never reach PayPal (src/lib/paypal.test.ts).

import { verifyBody, type WebhookHeaders } from "./model.ts";

export type PayPalEnv = "sandbox" | "live";

export interface PayPalConfig {
  env: PayPalEnv;
  baseUrl: string;
  clientId: string;
  clientSecret: string;
  webhookId: string | null;
}

export const PAYPAL_HOSTS: Record<PayPalEnv, string> = {
  sandbox: "https://api-m.sandbox.paypal.com",
  live: "https://api-m.paypal.com",
};

export function paypalConfig(get: (k: string) => string | undefined): PayPalConfig | null {
  const clientId = (get("PAYPAL_CLIENT_ID") ?? "").trim();
  const clientSecret = (get("PAYPAL_CLIENT_SECRET") ?? "").trim();
  if (!clientId || !clientSecret) return null;
  const env: PayPalEnv = (get("EXOS_PAYPAL_ENV") ?? "").trim().toLowerCase() === "live" ? "live" : "sandbox";
  return { env, baseUrl: PAYPAL_HOSTS[env], clientId, clientSecret, webhookId: (get("PAYPAL_WEBHOOK_ID") ?? "").trim() || null };
}

// The complete write allowlist. A path not matched here can only be a GET.
const ALLOWED_POSTS: readonly RegExp[] = [
  /^\/v1\/oauth2\/token$/,                                   // auth, not data
  /^\/v1\/notifications\/verify-webhook-signature$/,        // verification, not data
  /^\/v2\/checkout\/orders$/,                                // order create
  /^\/v2\/checkout\/orders\/[A-Z0-9]{8,40}\/capture$/,       // capture
  /^\/v2\/payments\/captures\/[A-Za-z0-9]{6,64}\/refund$/,   // refund
];
export const ALLOWED_HTTP_METHODS = new Set(["GET", "POST"]);

export function assertAllowed(method: string, path: string): void {
  if (!ALLOWED_HTTP_METHODS.has(method)) throw new Error(`paypal: ${method} is not allowed`);
  if (method === "POST" && !ALLOWED_POSTS.some((re) => re.test(path))) {
    throw new Error(`paypal: POST ${path} is not on the write allowlist`);
  }
}

export class PayPalError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly paypalName: string | null,
    readonly issues: string[],
    readonly debugId: string | null,
  ) {
    super(message);
    this.name = "PayPalError";
  }
  /** PayPal said no and created nothing: safe to give up (vs retry with the same request id). */
  get definitive(): boolean {
    return [400, 403, 404, 422].includes(this.status);
  }
  has(issue: string): boolean {
    return this.issues.includes(issue);
  }
}

type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

export interface PayPalClient {
  readonly env: PayPalEnv;
  createOrder(body: Record<string, unknown>, requestId: string): Promise<Record<string, unknown>>;
  getOrder(orderId: string): Promise<Record<string, unknown>>;
  captureOrder(orderId: string, requestId: string): Promise<Record<string, unknown>>;
  getCapture(captureId: string): Promise<Record<string, unknown>>;
  refundCapture(captureId: string, body: Record<string, unknown>, requestId: string): Promise<Record<string, unknown>>;
  verifyWebhook(h: WebhookHeaders, rawEvent: string): Promise<boolean>;
  listTransactions(q: { start: string; end: string; page?: number }): Promise<Record<string, unknown>>;
}

const enc = (s: string) => encodeURIComponent(s);

export function createPayPalClient(cfg: PayPalConfig, fetchImpl: Fetch = fetch, timeoutMs = 20_000): PayPalClient {
  let token: { value: string; until: number } | null = null;

  async function call(method: "GET" | "POST", path: string, opts: { body?: string; form?: string; requestId?: string; auth?: string } = {}) {
    assertAllowed(method, path.split("?")[0]);
    const headers: Record<string, string> = { Accept: "application/json" };
    if (opts.form != null) headers["Content-Type"] = "application/x-www-form-urlencoded";
    else if (opts.body != null) headers["Content-Type"] = "application/json";
    headers.Authorization = opts.auth ?? `Bearer ${await accessToken()}`;
    if (opts.requestId) headers["PayPal-Request-Id"] = opts.requestId;
    if (method === "POST" && opts.form == null) headers.Prefer = "return=representation";
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), timeoutMs);
    let res: Response;
    try {
      res = await fetchImpl(cfg.baseUrl + path, { method, headers, body: opts.form ?? opts.body, signal: ctl.signal });
    } finally {
      clearTimeout(timer);
    }
    const text = await res.text();
    let data: Record<string, unknown> = {};
    try { data = text ? JSON.parse(text) : {}; } catch { data = {}; }
    if (!res.ok) {
      const details = Array.isArray(data.details) ? data.details as { issue?: string }[] : [];
      throw new PayPalError(
        `paypal ${method} ${path.split("?")[0]}: ${res.status} ${String(data.name ?? "")} ${String(data.message ?? "")}`.trim(),
        res.status,
        typeof data.name === "string" ? data.name : null,
        details.map((d) => String(d.issue ?? "")).filter(Boolean),
        res.headers.get("paypal-debug-id") ?? (typeof data.debug_id === "string" ? data.debug_id : null),
      );
    }
    return data;
  }

  async function accessToken(): Promise<string> {
    if (token && Date.now() < token.until) return token.value;
    const basic = btoa(`${cfg.clientId}:${cfg.clientSecret}`);
    const data = await call("POST", "/v1/oauth2/token", { form: "grant_type=client_credentials", auth: `Basic ${basic}` });
    const value = typeof data.access_token === "string" ? data.access_token : "";
    if (!value) throw new PayPalError("paypal: no access token", 500, null, [], null);
    const ttl = Number(data.expires_in ?? 300);
    token = { value, until: Date.now() + Math.max(30, ttl - 60) * 1000 };
    return value;
  }

  const requestIdOk = (id: string) => {
    if (!/^[A-Za-z0-9_:.-]{1,108}$/.test(id)) throw new Error("paypal: bad PayPal-Request-Id");
    return id;
  };

  return {
    env: cfg.env,
    createOrder: (body, requestId) =>
      call("POST", "/v2/checkout/orders", { body: JSON.stringify(body), requestId: requestIdOk(requestId) }),
    getOrder: (orderId) => call("GET", `/v2/checkout/orders/${enc(orderId)}`),
    captureOrder: (orderId, requestId) =>
      call("POST", `/v2/checkout/orders/${enc(orderId)}/capture`, { body: "{}", requestId: requestIdOk(requestId) }),
    getCapture: (captureId) => call("GET", `/v2/payments/captures/${enc(captureId)}`),
    refundCapture: (captureId, body, requestId) =>
      call("POST", `/v2/payments/captures/${enc(captureId)}/refund`, { body: JSON.stringify(body), requestId: requestIdOk(requestId) }),
    async verifyWebhook(h, rawEvent) {
      if (!cfg.webhookId) throw new Error("paypal: PAYPAL_WEBHOOK_ID unset");
      // The raw text is spliced into the request, so it must be ONE JSON object.
      let parsed: unknown;
      try { parsed = JSON.parse(rawEvent); } catch { return false; }
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return false;
      const data = await call("POST", "/v1/notifications/verify-webhook-signature", { body: verifyBody(h, cfg.webhookId, rawEvent) });
      return data.verification_status === "SUCCESS";
    },
    listTransactions: ({ start, end, page = 1 }) =>
      call("GET", `/v1/reporting/transactions?start_date=${enc(start)}&end_date=${enc(end)}` +
        `&fields=transaction_info&page_size=500&page=${page}`),
  };
}
