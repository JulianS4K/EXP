// Tixel's fan-data webhook (mig 20261105120000, exos-tixel-webhook,
// docs/fans.md "Tixel waitlist signups"). Tixel posts every fan activity as JSON with the
// organizer's shared secret in the X-Secret header; only WAITLIST signups are
// kept. Inbound only: nothing is ever sent to Tixel.
//
// The secrets live in one env var, never in the database:
//   EXOS_TIXEL_WEBHOOK_SECRETS = {"<org id>": "<secret>", …}
// Each organizer pastes their own secret into Tixel, and the secret picks the
// org (as Opendate's X-Secret does). A secret is at least 16 characters.
//
// Pure TypeScript, imported by vitest.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const MIN_SECRET_LENGTH = 16;
export const MAX_TIXEL_BODY = 32 * 1024;

/** The env var as { secret, orgId } pairs; malformed entries are dropped (and counted). */
export function parseTixelSecrets(raw: string | undefined | null): { pairs: Array<{ orgId: string; secret: string }>; dropped: number } {
  if (!raw || !raw.trim()) return { pairs: [], dropped: 0 };
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    return { pairs: [], dropped: 1 };
  }
  if (!v || typeof v !== 'object' || Array.isArray(v)) return { pairs: [], dropped: 1 };
  const pairs: Array<{ orgId: string; secret: string }> = [];
  let dropped = 0;
  const seen = new Set<string>();
  for (const [orgId, secret] of Object.entries(v as Record<string, unknown>)) {
    if (!UUID_RE.test(orgId) || typeof secret !== 'string' || secret.length < MIN_SECRET_LENGTH || seen.has(secret)) {
      dropped++;
      continue;
    }
    seen.add(secret);
    pairs.push({ orgId: orgId.toLowerCase(), secret });
  }
  return { pairs, dropped };
}

function constantTimeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

/** The org whose secret this is, or null. Compares against every secret, in constant time each. */
export function orgForSecret(pairs: Array<{ orgId: string; secret: string }>, presented: string | null): string | null {
  if (!presented) return null;
  let hit: string | null = null;
  for (const p of pairs) if (constantTimeEqual(p.secret, presented)) hit = p.orgId;
  return hit;
}

/** The delivery as an object, or null (not JSON, not an object). */
export function parseTixelBody(text: string): Record<string, unknown> | null {
  try {
    const v = JSON.parse(text);
    return v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : null;
  } catch {
    return null;
  }
}
