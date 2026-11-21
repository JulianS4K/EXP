// Which browser origins an edge function's CORS answer may echo
// (Access-Control-Allow-Origin). CORS ONLY: never a redirect, return-URL,
// Turnstile hostname or OAuth check, which stay on EXOS_REDIRECT_ORIGINS alone
// (_shared/redirects.ts, docs/security.md "Allowed origins").
//
//   EXOS_REDIRECT_ORIGINS    the web app's origins (also allowed here)
//   EXOS_CORS_EXTRA_ORIGINS  the Exos native app's web view origins
//                            (docs/native-apps.md), comma-separated. Only the
//                            exact values in NATIVE_APP_ORIGINS are kept;
//                            anything else (a wildcard, another host) is
//                            dropped. They can call our APIs from the app,
//                            but nothing is ever redirected or returned there.
// Imports only redirects.ts (itself import-free), so Deno and vitest can both load it.

import { parseRedirectOrigins } from "./redirects.ts";

/**
 * Capacitor's origins: iOS (capacitor://localhost), Android (https://localhost;
 * apps/native/capacitor.config.ts sets androidScheme 'https', so http:// is
 * never the app's and isn't accepted).
 */
export const NATIVE_APP_ORIGINS = ["capacitor://localhost", "https://localhost"] as const;

/**
 * The CORS-only extras that are on the native list, exactly; the rest dropped.
 * An origin has no path, so "https://localhost/" (trailing slash) is dropped too.
 */
export function parseCorsExtraOrigins(raw: string | undefined | null): string[] {
  const ok = new Set<string>(NATIVE_APP_ORIGINS);
  return (raw ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => ok.has(s));
}

/** Origins a CORS answer may echo: the redirect allow-list plus the native extras. */
export function corsAllowedOrigins(redirectOriginsRaw: string | undefined | null, extraRaw: string | undefined | null): string[] {
  return [...new Set([...parseRedirectOrigins(redirectOriginsRaw), ...parseCorsExtraOrigins(extraRaw)])];
}
