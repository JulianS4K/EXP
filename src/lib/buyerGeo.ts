// "Where buyers are" (mig 20261106140000): the event report's Marketing tab
// and the org rollup. The numbers come from exos_event_buyer_geo /
// exos_org_buyer_geo (owner / manager / finance; SQL aggregates, the panel
// never reads a single order's location). Locations are the billing address
// Stripe or PayPal gave at payment: country, region, city. Never an IP
// lookup, never a street. Pure (vitest: buyerGeo.test.ts); the reads are in
// buyerGeoApi.ts.

export interface GeoRow {
  country: string | null;
  region?: string | null;
  city?: string | null;
  currency: string;
  orders: number;
  tickets: number;
  gross_cents: number;
}

export interface BuyerGeoReport {
  orders: number;
  tickets: number;
  located_orders: number;
  unknown_orders: number;
  countries: GeoRow[];
  cities: GeoRow[];
  unknown: GeoRow[];
  other_tickets: number;
}

const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : Number(v) || 0);
const str = (v: unknown) => (typeof v === 'string' && v ? v : null);

function row(r: unknown): GeoRow {
  const o = (r ?? {}) as Record<string, unknown>;
  return {
    country: str(o.country), region: str(o.region), city: str(o.city), currency: str(o.currency) ?? 'USD',
    orders: num(o.orders), tickets: num(o.tickets), gross_cents: num(o.gross_cents),
  };
}

/** The RPC's jsonb as a typed report (missing pieces read as empty). */
export function parseBuyerGeo(raw: unknown): BuyerGeoReport | null {
  if (!raw || typeof raw !== 'object') return null;
  const o = raw as Record<string, unknown>;
  const list = (v: unknown) => (Array.isArray(v) ? v.map(row) : []);
  return {
    orders: num(o.orders), tickets: num(o.tickets), located_orders: num(o.located_orders), unknown_orders: num(o.unknown_orders),
    countries: list(o.countries), cities: list(o.cities), unknown: list(o.unknown), other_tickets: num(o.other_tickets),
  };
}

/** "US" -> "United States" (the viewer's language); the code itself when the browser can't name it. */
export function countryName(code: string | null, locale?: string): string {
  if (!code) return 'Unknown';
  try {
    const dn = new Intl.DisplayNames(locale ? [locale] : undefined, { type: 'region' });
    return dn.of(code) ?? code;
  } catch {
    return code;
  }
}

/** "Brooklyn, NY" / "London, United Kingdom". */
export function cityLabel(r: GeoRow, locale?: string): string {
  const where = r.region && r.country === 'US' ? r.region : countryName(r.country, locale);
  return r.city ? `${r.city}, ${where}` : where;
}

/** Share of orders, 0-100, rounded; 0 when there are none. */
export function sharePct(part: number, total: number): number {
  return total > 0 ? Math.round((part / total) * 100) : 0;
}

/** The countries table: the top rows, then one "Unknown" row per currency. */
export function countryRows(r: BuyerGeoReport): GeoRow[] {
  return [...r.countries, ...r.unknown.filter((u) => u.orders > 0)];
}

/** True when the rows mix currencies (the panel then labels each amount). */
export function mixedCurrencies(r: BuyerGeoReport): boolean {
  return new Set([...r.countries, ...r.unknown].map((x) => x.currency)).size > 1;
}
