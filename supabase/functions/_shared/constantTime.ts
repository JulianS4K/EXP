// Comparing secrets (webhook tokens, signatures, cron secrets, barcode
// HMACs) without an early exit on the first differing character.
//
// Pure TypeScript, no imports: loaded by Deno and by the app (vite, vitest).

/**
 * True when `a` and `b` are the same string. Every UTF-16 code unit of the
 * longer one is compared, so the time taken doesn't say where they differ;
 * only a length mismatch shows (fine for the fixed-length secrets compared
 * here). Callers that must fail closed on an empty expected value check that
 * themselves.
 */
export function constantTimeEqual(a: string, b: string): boolean {
  let diff = a.length ^ b.length;
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}
