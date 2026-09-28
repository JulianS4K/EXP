// Network errors from a marketplace fetch, without the URL or any secret.
//
// When fetch() itself throws (DNS, TLS, reset, timeout), Deno's message
// carries the full request URL: "error sending request for url
// (https://host/path?source=KEY)". Gametime puts its key in the query string
// and Vivid v1 its apiToken, so the raw error must never reach a log line, a
// JSON response or a stored note. guardedFetch() rethrows it as a
// MarketplaceNetworkError naming only the endpoint (method + path template),
// with any URL stripped and every known secret redacted from the detail, and
// without `cause` (which would carry the original message).

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export type Secrets = ReadonlyArray<string | null | undefined>;

/** Every trace of the given secrets (raw and URL-encoded) out of a string. */
export function redactSecrets(s: string, secrets: Secrets): string {
  let out = s;
  for (const secret of secrets) {
    if (!secret || secret.length < 4) continue;
    for (const form of new Set([secret, encodeURIComponent(secret), new URLSearchParams({ x: secret }).toString().slice(2)])) {
      out = out.split(form).join('[redacted]');
    }
  }
  return out;
}

/** URLs out of a string (the whole URL: host, path and query). */
export function stripUrls(s: string): string {
  return s.replace(/\b[a-z][a-z0-9+.-]*:\/\/[^\s)"'<>]+/gi, '[url]');
}

export class MarketplaceNetworkError extends Error {
  /** "gametime GET /v1/purchases": the endpoint, never the URL. */
  readonly endpoint: string;
  constructor(endpoint: string, detail: string) {
    super(`${endpoint}: network error${detail ? ` (${detail})` : ''}`);
    this.name = 'MarketplaceNetworkError';
    this.endpoint = endpoint;
  }
}

/** A thrown value's text, safe to log: no URL, no secret, bounded. */
export function safeErrorText(e: unknown, secrets: Secrets = []): string {
  const raw = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
  return redactSecrets(stripUrls(redactSecrets(raw, secrets)), secrets).slice(0, 300);
}

/**
 * fetch(url, init), but a thrown network error comes back as a
 * MarketplaceNetworkError labelled `endpoint` (e.g. "vivid GET
 * /v1/getOrders"). HTTP error statuses are returned as usual.
 */
export async function guardedFetch(
  fetchImpl: FetchLike,
  url: string,
  init: RequestInit,
  endpoint: string,
  secrets: Secrets = [],
): Promise<Response> {
  try {
    return await fetchImpl(url, init);
  } catch (e) {
    throw new MarketplaceNetworkError(endpoint, safeErrorText(e, secrets));
  }
}
