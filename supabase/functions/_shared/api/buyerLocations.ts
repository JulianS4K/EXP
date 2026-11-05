// Query parameters of the buyer-location reports (mig 20261106140000,
// exos-api/buyerGeoGenre.ts). Pure TypeScript, imported by vitest
// (src/lib/apiGenres.test.ts).

/** An answer with a status (index.ts sends it as JSON). */
export class GeoGenreError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export const ISO_RE = /^\d{4}-\d{2}-\d{2}([T ][0-9:.]+(Z|[+-]\d{2}:?\d{2})?)?$/;

/** ?limit= of the reports: 1-100, default 10. */
export function reportLimit(q: URLSearchParams): number {
  const v = q.get("limit");
  if (v === null || v === "") return 10;
  if (!/^\d{1,3}$/.test(v) || Number(v) < 1 || Number(v) > 100) throw new GeoGenreError(400, "limit must be 1-100.");
  return Number(v);
}

/** ?since= of the org report: an ISO date or time, or null. */
export function reportSince(q: URLSearchParams): string | null {
  const v = q.get("since");
  if (v === null || v === "") return null;
  if (!ISO_RE.test(v) || Number.isNaN(Date.parse(v))) throw new GeoGenreError(400, "since must be an ISO 8601 date or time.");
  return new Date(v).toISOString();
}
