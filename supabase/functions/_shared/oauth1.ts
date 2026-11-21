// OAuth 1.0a request signing (HMAC-SHA1, RFC 5849), for the X Ads API (the
// X Conversions API sender, channels/adapters/xAds.ts). Pure: Web Crypto only,
// so the Deno tests and vitest import it.
//
// The signature covers the method, the URL without its query, and the query
// parameters plus the oauth_* ones, percent-encoded per RFC 3986 and sorted.
// A JSON body is not part of the signature (only a form body is). The keys
// never appear in the result except as the header value, which GatedHttp
// redacts (Authorization) from every audit step.

export interface OAuth1Keys {
  consumerKey: string;
  consumerSecret: string;
  token: string;
  tokenSecret: string;
}

/** RFC 3986 percent-encoding (encodeURIComponent leaves !'()* alone). */
export function pctEncode(s: string): string {
  return encodeURIComponent(s).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}

/** A random nonce: 32 hex characters. */
export function oauthNonce(): string {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

/** The signature base string (exported for the test vector). */
export function signatureBase(method: string, url: string, params: Record<string, string>, extra: Array<[string, string]> = []): string {
  const u = new URL(url);
  const pairs: Array<[string, string]> = [...extra];
  u.searchParams.forEach((v, k) => pairs.push([k, v]));
  for (const [k, v] of Object.entries(params)) pairs.push([k, v]);
  const enc = pairs.map(([k, v]) => [pctEncode(k), pctEncode(v)] as [string, string])
    .sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0) : a[0] < b[0] ? -1 : 1));
  const norm = enc.map(([k, v]) => `${k}=${v}`).join("&");
  const baseUrl = `${u.protocol}//${u.host.toLowerCase()}${u.pathname}`;
  return [method.toUpperCase(), pctEncode(baseUrl), pctEncode(norm)].join("&");
}

async function hmacSha1Base64(key: string, data: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(data)));
  let s = "";
  for (const b of sig) s += String.fromCharCode(b);
  return btoa(s);
}

/**
 * The Authorization header value for one request. `formBody` only for an
 * application/x-www-form-urlencoded body (its pairs are signed); a JSON body
 * is not signed. nonce / timestamp are injectable for tests.
 */
export async function oauth1Header(
  method: string, url: string, keys: OAuth1Keys,
  opts: { nonce?: string; timestamp?: number; formBody?: Array<[string, string]> } = {},
): Promise<string> {
  const oauth: Record<string, string> = {
    oauth_consumer_key: keys.consumerKey,
    oauth_nonce: opts.nonce ?? oauthNonce(),
    oauth_signature_method: "HMAC-SHA1",
    oauth_timestamp: String(opts.timestamp ?? Math.floor(Date.now() / 1000)),
    oauth_token: keys.token,
    oauth_version: "1.0",
  };
  const base = signatureBase(method, url, oauth, opts.formBody ?? []);
  const signature = await hmacSha1Base64(`${pctEncode(keys.consumerSecret)}&${pctEncode(keys.tokenSecret)}`, base);
  const all: Record<string, string> = { ...oauth, oauth_signature: signature };
  return "OAuth " + Object.keys(all).sort().map((k) => `${pctEncode(k)}="${pctEncode(all[k])}"`).join(", ");
}

/** The org's X token pair from the store secret (JSON {token, token_secret}), or null. */
export function parseXTokenSecret(secret: string | null | undefined): { token: string; tokenSecret: string } | null {
  if (!secret) return null;
  try {
    const o = JSON.parse(secret) as Record<string, unknown>;
    const token = typeof o.token === "string" ? o.token.trim() : "";
    const tokenSecret = typeof o.token_secret === "string" ? o.token_secret.trim() : "";
    return token && tokenSecret ? { token, tokenSecret } : null;
  } catch {
    return null;
  }
}
