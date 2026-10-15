// SMS through the organizer's own Twilio / Telnyx account (mig 20261016120000).
// Sending and webhook verification; pure where it can be.

type Fetch = typeof fetch;

export interface SmsConfig { provider: "twilio" | "telnyx"; config: Record<string, unknown>; secret: string | null }
export type SendResult = { ok: true; id: string } | { ok: false; retry: boolean; error: string };

const E164 = /^\+[1-9][0-9]{7,14}$/;

export async function sendSms(f: Fetch, c: SmsConfig, to: string, body: string): Promise<SendResult> {
  if (!E164.test(to)) return { ok: false, retry: false, error: "bad number" };
  if (!c.secret) return { ok: false, retry: false, error: "no credentials" };
  const from = String(c.config.from ?? "");
  if (c.provider === "twilio") {
    const sid = String(c.config.account_sid ?? "");
    if (!/^(AC|SK)[0-9a-fA-F]{32}$/.test(sid)) return { ok: false, retry: false, error: "bad account sid" };
    const form = new URLSearchParams({ To: to, Body: body });
    if (/^MG[0-9a-fA-F]{32}$/.test(from)) form.set("MessagingServiceSid", from);
    else if (E164.test(from)) form.set("From", from);
    else return { ok: false, retry: false, error: "bad sender" };
    const r = await f(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
      method: "POST", redirect: "manual",
      headers: { Authorization: `Basic ${btoa(`${sid}:${c.secret}`)}`, "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    return outcome(r, (b) => (typeof b?.sid === "string" ? b.sid : null), (b) => b?.message);
  }
  if (!E164.test(from)) return { ok: false, retry: false, error: "bad sender" };
  const payload: Record<string, unknown> = { from, to, text: body };
  if (typeof c.config.messaging_profile_id === "string" && c.config.messaging_profile_id) payload.messaging_profile_id = c.config.messaging_profile_id;
  const r = await f("https://api.telnyx.com/v2/messages", {
    method: "POST", redirect: "manual",
    headers: { Authorization: `Bearer ${c.secret}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  return outcome(r, (b) => (typeof b?.data?.id === "string" ? b.data.id : null), (b) => b?.errors?.[0]?.detail);
}

async function outcome(r: Response, id: (b: any) => string | null, msg: (b: any) => unknown): Promise<SendResult> {
  const b = await r.json().catch(() => ({}));
  if (r.ok && id(b)) return { ok: true, id: id(b)! };
  const text = typeof msg(b) === "string" ? String(msg(b)).slice(0, 180) : `HTTP ${r.status}`;
  // Rate limits and server errors are worth another try; the rest isn't.
  return { ok: false, retry: r.status === 429 || r.status >= 500, error: text };
}

/** Twilio's X-Twilio-Signature: base64(HMAC-SHA1(token, url + each sorted key+value)). */
export async function twilioSignature(url: string, params: Record<string, string>, token: string): Promise<string> {
  const data = url + Object.keys(params).sort().map((k) => k + params[k]).join("");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(token), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)));
  return btoa(String.fromCharCode(...sig));
}

export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

/** Telnyx webhooks: Ed25519 over "<timestamp>|<raw body>"; rejects anything older than 5 minutes. */
export async function telnyxVerified(rawBody: string, signatureB64: string, timestamp: string, publicKeyB64: string, now = Date.now()): Promise<boolean> {
  try {
    const ts = Number(timestamp);
    if (!Number.isFinite(ts) || Math.abs(now / 1000 - ts) > 300) return false;
    const key = await crypto.subtle.importKey("raw", b64(publicKeyB64), { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, b64(signatureB64), new TextEncoder().encode(`${timestamp}|${rawBody}`));
  } catch {
    return false;
  }
}

/** The reply's sender and text from a Telnyx message.received event. */
export function telnyxInbound(body: any): { from: string; text: string } | null {
  if (body?.data?.event_type !== "message.received") return null;
  const p = body.data.payload ?? {};
  const from = p?.from?.phone_number;
  return typeof from === "string" ? { from, text: typeof p.text === "string" ? p.text : "" } : null;
}
