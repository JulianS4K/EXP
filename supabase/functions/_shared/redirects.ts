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

/** localhost, *.localhost, 127.0.0.0/8, ::1 (bracketed or not), 0.0.0.0. */
export function isLoopbackHost(hostname: string): boolean {
  const h = hostname.trim().toLowerCase().replace(/\.$/, "");
  return h === "localhost" || h.endsWith(".localhost") || /^127\.\d+\.\d+\.\d+$/.test(h)
    || h === "::1" || h === "[::1]" || h === "0.0.0.0" || h === "[::]";
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
