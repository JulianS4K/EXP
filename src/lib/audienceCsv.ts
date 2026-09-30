// Customer-list CSVs for custom audiences (docs/marketing-catalog.md →
// "Audience export"). The rows come from exos_org_audience_export (mig
// 20260930101000), which returns SHA-256 hashes only; this file just lays
// them out the way each ad platform's customer-list upload expects.
//
//   Meta:   headers "email,phone"; phone hashed from digits with the country
//           code and no "+" (phone_digits_sha256).
//   Google: Customer Match headers "Email,Phone"; phone hashed from E.164
//           with the "+" (phone_sha256).
//   TikTok: multi-ID file headers "email_sha256,phone_sha256"; phone hashed
//           from E.164 with the "+" (phone_sha256).
// A row without a phone leaves that cell empty. Pure: no network, no DOM.

export type AudiencePlatform = 'meta' | 'google' | 'tiktok';

export interface AudienceRow {
  email_sha256: string;
  phone_sha256: string | null;
  phone_digits_sha256: string | null;
}

export interface AudienceExport {
  count: number;
  generated_at: string;
  rows: AudienceRow[];
}

export const AUDIENCE_PLATFORMS: readonly { id: AudiencePlatform; label: string }[] = [
  { id: 'meta', label: 'Meta (Facebook / Instagram)' },
  { id: 'google', label: 'Google Customer Match' },
  { id: 'tiktok', label: 'TikTok' },
];

const HEADERS: Record<AudiencePlatform, readonly [string, string]> = {
  meta: ['email', 'phone'],
  google: ['Email', 'Phone'],
  tiktok: ['email_sha256', 'phone_sha256'],
};

const HEX64 = /^[0-9a-f]{64}$/;

/** Only a lower-case 64-char hex SHA-256 passes; anything else becomes an empty cell. */
function hash(v: unknown): string {
  return typeof v === 'string' && HEX64.test(v) ? v : '';
}

/** The CSV for one platform: header row, one row per person, CRLF line ends. */
export function audienceCsv(rows: readonly AudienceRow[], platform: AudiencePlatform): string {
  const lines = [HEADERS[platform].join(',')];
  for (const r of rows) {
    const email = hash(r.email_sha256);
    if (!email) continue;
    const phone = hash(platform === 'meta' ? r.phone_digits_sha256 : r.phone_sha256);
    lines.push(`${email},${phone}`);
  }
  return lines.join('\r\n') + '\r\n';
}

/** "blue-room-meta-audience-2026-09-30.csv" (or with the event slug). */
export function audienceFilename(orgSlug: string, platform: AudiencePlatform, date: Date, eventSlug?: string | null): string {
  const safe = (s: string) => s.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);
  const parts = [safe(orgSlug) || 'org', eventSlug ? safe(eventSlug) : '', platform, 'audience', date.toISOString().slice(0, 10)];
  return `${parts.filter(Boolean).join('-')}.csv`;
}

/** Validates the RPC's answer; throws on anything that isn't hashes only. */
export function parseAudienceExport(v: unknown): AudienceExport {
  const o = (v && typeof v === 'object' ? v : {}) as Record<string, unknown>;
  if (!Array.isArray(o.rows)) throw new Error('Unexpected export response');
  const rows: AudienceRow[] = [];
  for (const r of o.rows as Array<Record<string, unknown>>) {
    const email = hash(r?.email_sha256);
    if (!email) throw new Error('Unexpected export response');
    rows.push({ email_sha256: email, phone_sha256: hash(r.phone_sha256) || null, phone_digits_sha256: hash(r.phone_digits_sha256) || null });
  }
  return { count: rows.length, generated_at: typeof o.generated_at === 'string' ? o.generated_at : '', rows };
}

// ── Catalog feed URLs (supabase/functions/exos-catalog-feed) ─────────

export interface CatalogFeedLink {
  platform: AudiencePlatform;
  label: string;
  url: string;
}

/** The feed URL per platform for an org, or [] when the functions base is unknown. */
export function catalogFeedLinks(functionsBase: string, orgSlug: string): CatalogFeedLink[] {
  const base = functionsBase.replace(/\/+$/, '');
  if (!base || !/^[a-z0-9][a-z0-9-]{0,79}$/.test(orgSlug)) return [];
  const u = `${base}/exos-catalog-feed/${orgSlug}`;
  return [
    { platform: 'meta', label: 'Meta Commerce Manager (CSV)', url: `${u}.csv?format=meta` },
    { platform: 'tiktok', label: 'TikTok Catalog Manager (CSV)', url: `${u}.csv?format=tiktok` },
    { platform: 'google', label: 'Google Merchant Center (XML)', url: `${u}.xml?format=google` },
  ];
}
