// Where exos-checkout and exos-connect-onboard may send a browser back to.
// The URLs come from the client, so without a check anyone could mint a
// Stripe-hosted page that bounces the buyer to a lookalike site.
//
// Allowed: an exact origin from EXOS_REDIRECT_ORIGINS (comma-separated, e.g.
// "https://vibepass-storefront-test.onrender.com,https://exos.example"), over
// https, with no embedded credentials. A loopback host (localhost,
// *.localhost, 127.x, ::1, 0.0.0.0) is never a target, even when configured:
// on a phone, another app can listen there (the native app's web view origins
// are CORS-only, _shared/corsOrigins.ts). Local development returns through an
// https tunnel. No imports, so Deno and EXP's vitest can both load it.

export function parseRedirectOrigins(raw: string | undefined | null): string[] {
  return (raw ?? "")
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, ""))
    .filter((s) => s.length > 0);
}

/**
 * localhost, *.localhost, 127.0.0.0/8, ::1, ::, 0.0.0.0, and 127.0.0.0/8 as an
 * IPv6 address (::ffff:127.x.x.x, ::127.x.x.x; URL writes them as ::ffff:7fxx:x
 * and ::7fxx:x). IPv6 forms bracketed or not.
 */
export function isLoopbackHost(hostname: string): boolean {
  const h = hostname.trim().toLowerCase().replace(/\.$/, "");
  const v6 = h.replace(/^\[(.*)\]$/, "$1");
  return h === "localhost" || h.endsWith(".localhost") || /^127\.\d+\.\d+\.\d+$/.test(h)
    || h === "0.0.0.0" || v6 === "::1" || v6 === "::"
    || /^::(ffff:)?(7f[0-9a-f]{2}:[0-9a-f]{1,4}|127\.\d+\.\d+\.\d+)$/.test(v6);
}

export function isAllowedRedirect(url: unknown, allowedOrigins: string[]): boolean {
  if (typeof url !== "string" || url.length > 2048) return false;
  let u: URL;
  try { u = new URL(url); } catch { return false; }
  if (u.username || u.password) return false;
  if (u.protocol !== "https:" || isLoopbackHost(u.hostname)) return false;
  return allowedOrigins.includes(u.origin);
}

// Embedded Checkout's return_url (exos-checkout ui_mode 'embedded'): an
// allowlisted origin AND our own /embed/return page (optionally under one base
// path segment, e.g. /bridge/embed/return), no fragment. Query is free — it
// carries Stripe's {CHECKOUT_SESSION_ID} template, the event id and the host
// origin the return page reports back to.
export function isAllowedEmbedReturn(url: unknown, allowedOrigins: string[]): boolean {
  if (!isAllowedRedirect(url, allowedOrigins)) return false;
  const u = new URL(url as string);
  if (u.hash) return false;
  return /^(\/[A-Za-z0-9_-]+)?\/embed\/return\/?$/.test(u.pathname);
}
