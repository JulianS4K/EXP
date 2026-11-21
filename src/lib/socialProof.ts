// Social proof shown to buyers (UX quick wins, 2026-11-21): a follower count
// only once it helps. "0 followers" (or 3) on a new organizer's storefront
// reads as "nobody goes to this", so below FOLLOWER_COUNT_MIN nothing shows.

export const FOLLOWER_COUNT_MIN = 10;

/** "1,234 followers", or null below the threshold (or for a bad count). */
export function followerLabel(n: number | null | undefined, locale?: string): string | null {
  const c = Math.floor(Number(n));
  if (!Number.isFinite(c) || c < FOLLOWER_COUNT_MIN) return null;
  return `${c.toLocaleString(locale)} followers`;
}
