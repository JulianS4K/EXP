// Error reporting for the edge functions.
//
//   reportError("exos-marketplace-sales", err, { phase: "gametime" })
//
// Logs one scrubbed line (console.error) and, when SENTRY_DSN is set, POSTs a
// minimal event to Sentry's store endpoint (the DSN key goes in the
// X-Sentry-Auth header, never in a URL). Scrubbing (_shared/scrub.ts) removes
// emails, credentials, tokens and URL query strings, plus the value of every
// secret-looking environment variable (*_KEY, *_TOKEN, *_SECRET,
// *AUTHORIZATION, *_DSN, *PASSWORD). Reporting never throws: a failed POST is
// dropped after a short timeout.
//
// Env: SENTRY_DSN (optional), SENTRY_ENVIRONMENT (optional, default
// "production").

import { parseSentryDsn, scrub, scrubError, scrubStack, sentryAuthHeader, sentryEvent, sentryStoreUrl } from "./scrub.ts";

type EnvGet = (k: string) => string | undefined;
type EnvAll = () => Record<string, string>;

const SECRET_NAME = /(_KEY|_TOKEN|_SECRET|AUTHORIZATION|_DSN|PASSWORD|_ACCESS_ID)$/i;

function denoEnv(): { get: EnvGet; all: EnvAll } {
  // deno-lint-ignore no-explicit-any
  const D = (globalThis as any).Deno;
  return {
    get: (k) => {
      try {
        return D?.env?.get(k) ?? undefined;
      } catch {
        return undefined;
      }
    },
    all: () => {
      try {
        return D?.env?.toObject() ?? {};
      } catch {
        return {};
      }
    },
  };
}

/** Values of the secret-looking env vars, for redaction. */
export function secretValues(all: Record<string, string>): string[] {
  return Object.entries(all)
    .filter(([k, v]) => SECRET_NAME.test(k) && typeof v === "string" && v.length >= 6)
    .map(([, v]) => v);
}

export interface ReportDeps {
  env?: { get: EnvGet; all: EnvAll };
  fetch?: (input: string, init?: RequestInit) => Promise<Response>;
  log?: (...args: unknown[]) => void;
}

/** Scrubbed text of `err`, safe for a log line or a JSON error body. */
export function redactError(err: unknown, deps: ReportDeps = {}): string {
  const env = deps.env ?? denoEnv();
  return scrubError(err, secretValues(env.all()), 500);
}

export async function reportError(fn: string, err: unknown, extra: Record<string, string> = {}, deps: ReportDeps = {}): Promise<void> {
  const env = deps.env ?? denoEnv();
  const secrets = secretValues(env.all());
  const message = scrubError(err, secrets, 1000);
  const tags: Record<string, string> = { function: fn };
  for (const [k, v] of Object.entries(extra)) tags[k] = scrub(String(v), secrets).slice(0, 200);
  (deps.log ?? console.error)(`${fn}: ${message}`, Object.keys(extra).length ? tags : "");
  const dsn = parseSentryDsn(env.get("SENTRY_DSN"));
  if (!dsn) return;
  const doFetch = deps.fetch ?? ((input: string, init?: RequestInit) => fetch(input, init));
  try {
    await doFetch(sentryStoreUrl(dsn), {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Sentry-Auth": sentryAuthHeader(dsn, "exos-edge/1.0") },
      body: JSON.stringify(sentryEvent({
        message,
        exceptionType: err instanceof Error ? err.name : undefined,
        stack: scrubStack(err, secrets),
        platform: "node",
        logger: fn,
        environment: env.get("SENTRY_ENVIRONMENT") ?? "production",
        tags,
      })),
      signal: AbortSignal.timeout(3000),
    });
  } catch {
    // Reporting is best-effort; never let it mask the original failure.
  }
}
