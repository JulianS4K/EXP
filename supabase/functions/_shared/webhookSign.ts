// Exos webhook signatures (exos-webhook-drain; docs/api/_meta.json "webhooks").
//
//   X-Exos-Timestamp: <unix seconds when this attempt was sent>
//   X-Exos-Signature: sha256=<hex HMAC-SHA256(secret, `${timestamp}.${rawBody}`)>
//   X-Exos-Delivery:  <delivery id, the same on every retry>
//
// signWebhook is what the drain sends; verifyWebhook is the receiver's recipe
// (raw body, constant-time compare, a 300-second window), kept here so the
// documented recipe is the tested one (src/lib/sim/partner.test.ts).
//
// Pure TypeScript (WebCrypto only), imported by vitest.

export const WEBHOOK_TOLERANCE_SECONDS = 300;

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** The X-Exos-Signature value for this body at this timestamp. */
export async function signWebhook(secret: string, timestamp: string, rawBody: string): Promise<string> {
  return `sha256=${await hmacSha256Hex(secret, `${timestamp}.${rawBody}`)}`;
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export type WebhookCheck = 'ok' | 'missing' | 'bad_signature' | 'stale';

/** A receiver's check of one delivery (nowSeconds: the receiver's clock). */
export async function verifyWebhook(
  secret: string, headers: { timestamp: string | null; signature: string | null }, rawBody: string,
  nowSeconds: number, tolerance = WEBHOOK_TOLERANCE_SECONDS,
): Promise<WebhookCheck> {
  const { timestamp, signature } = headers;
  if (!timestamp || !signature || !/^\d{1,12}$/.test(timestamp)) return 'missing';
  const expected = await signWebhook(secret, timestamp, rawBody);
  if (!sameText(expected, signature.trim().toLowerCase())) return 'bad_signature';
  if (Math.abs(nowSeconds - Number(timestamp)) > tolerance) return 'stale';
  return 'ok';
}
