// Server-side link previews + sitemap for the Exos SPA (/bridge/*).
//
// Exos sells through Instagram bios, stories, WhatsApp and iMessage, and the
// unfurl bots behind those don't run JavaScript, so the per-event tags the
// SPA sets client-side (src/lib/meta.ts) never reach them. For crawlers
// (crawler.ts) the server picks a preview target from the URL, reads the
// PUBLIC views, and splices tags between the SSR_META markers in index.html.
//
// Ported from Terminal-2 core/exos_seo.py when Exos moved to its own host
// (behaviour-identical; its tests are ported in seo.test.ts). Pure apart from
// the injected `PublicReader`, and any miss returns null so a crawler never
// sees less than the static card.

export const SSR_META_START = '<!-- SSR_META_START -->';
export const SSR_META_END = '<!-- SSR_META_END -->';

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
const SLUG = '[A-Za-z0-9][A-Za-z0-9_-]{0,99}';
const EVENT_RE = new RegExp(`^event/(${UUID})/?$`);
const EVENT_SLUG_RE = new RegExp(`^e/(${SLUG})/?$`);
const ORG_RE = new RegExp(`^o/(${SLUG})/?$`);
const PROMOTER_RE = new RegExp(`^promoter/(${UUID})/[A-Za-z0-9_-]{1,64}/?$`);
// Promoter link-in-bio (/l/:orgSlug/:code) previews as the organizer.
const BIO_RE = new RegExp(`^l/(${SLUG})/[A-Za-z0-9_-]{1,64}/?$`);
const UUID_RE = new RegExp(`^${UUID}$`);

export type PreviewKind = 'event' | 'event_slug' | 'org' | 'promoter' | 'checkout_event' | 'checkout_tier';
export type PreviewTarget = [PreviewKind, string];

/** Which record a /bridge/<page>?<query> link previews, or null. */
export function previewTarget(page: string, query = ''): PreviewTarget | null {
  let m: RegExpMatchArray | null;
  if ((m = page.match(EVENT_RE))) return ['event', m[1].toLowerCase()];
  if ((m = page.match(EVENT_SLUG_RE))) return ['event_slug', m[1]];
  if ((m = page.match(ORG_RE) || page.match(BIO_RE))) return ['org', m[1]];
  if ((m = page.match(PROMOTER_RE))) return ['promoter', m[1].toLowerCase()];
  if (page.replace(/\/+$/, '') === 'checkout') {
    const q = new URLSearchParams(query || '');
    const ev = q.get('event') ?? '';
    if (UUID_RE.test(ev)) return ['checkout_event', ev.toLowerCase()];
    const first = (q.get('products') ?? '').split(',')[0].split(':')[0].trim();
    if (UUID_RE.test(first)) return ['checkout_tier', first.toLowerCase()];
  }
  return null;
}

// ── Prices ───────────────────────────────────────────────────────────

/** ISO string → epoch ms; a string without a zone is read as UTC. NaN if unparseable. */
function parseInstant(v: string): number {
  const s = /(?:Z|[+-]\d{2}:?\d{2})$/i.test(v) ? v : `${v}Z`;
  return Date.parse(s);
}

/** Mirror of src/lib/pricing.ts effectiveTierPrice (latest started step). */
export function effectivePrice(base: number, schedule: unknown, now: Date): number {
  let price = base;
  if (!Array.isArray(schedule)) return price;
  const steps: Array<[number, number]> = [];
  for (const st of schedule) {
    if (!st || typeof st !== 'object') continue;
    const { price: p, startsAt: at } = st as { price?: unknown; startsAt?: unknown };
    if (typeof p !== 'number' || p < 0 || typeof at !== 'string') continue;
    const t = parseInstant(at);
    if (Number.isNaN(t)) continue;
    steps.push([t, p]);
  }
  steps.sort((a, b) => a[0] - b[0]);
  for (const [t, p] of steps) if (t <= now.getTime()) price = p;
  return price;
}

interface TierRow {
  price?: unknown;
  price_schedule?: unknown;
  exclusive_tax_percent?: unknown;
}

/** Lowest all-in (price + exclusive tax) tier price in cents, as the storefront shows it. */
export function fromPriceCents(tiers: TierRow[], now: Date = new Date()): number | null {
  let best: number | null = null;
  for (const t of tiers ?? []) {
    const base = Number(t.price ?? 0);
    if (!Number.isFinite(base)) continue;
    const unit = Math.round(effectivePrice(base, t.price_schedule, now) * 100);
    const rate = Number(t.exclusive_tax_percent ?? 0) || 0;
    const allIn = unit + Math.round((unit * rate) / 100);
    best = best === null ? allIn : Math.min(best, allIn);
  }
  return best;
}

const CURRENCY_SYMBOLS: Record<string, string> = { USD: '$', EUR: '€', GBP: '£', CAD: 'CA$', AUD: 'A$' };

export function money(cents: number, currency: string): string {
  if (cents === 0) return 'Free';
  const code = (currency || 'USD').toUpperCase();
  const amount = (cents / 100)
    .toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    .replace('.00', '');
  const sym = CURRENCY_SYMBOLS[code];
  return sym ? `${sym}${amount}` : `${amount} ${code}`;
}

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * "Fri Oct 2 · 10 PM", from the wall-clock time exactly as written (the
 * organizer's local time when present), never shifted into another zone.
 */
export function dateLabel(startsAt: string | null | undefined, local: string | null | undefined): string | null {
  const raw = local || startsAt;
  if (!raw) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(raw);
  if (!m) return null;
  const [y, mo, d, h, mi] = m.slice(1).map((x) => Number(x ?? 0));
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
  const weekday = DAYS[new Date(Date.UTC(y, mo - 1, d)).getUTCDay()];
  const hour12 = h % 12 === 0 ? 12 : h % 12;
  const time = mi === 0 ? `${hour12} ${h < 12 ? 'AM' : 'PM'}` : `${hour12}:${String(mi).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
  return `${weekday} ${MONTHS[mo - 1]} ${d} · ${time}`;
}

// ── Tags ─────────────────────────────────────────────────────────────

export interface EventSummary {
  id: unknown;
  name: string;
  date: string | null;
  startsAt: string | null;
  venue: string | null;
  city?: string;
  region?: string;
  street?: string;
  image?: string;
  description: string;
  from: string | null;
  fromCents: number | null;
  currency: string;
  orgName?: string;
}

type Row = Record<string, unknown>;
const str = (v: unknown) => (typeof v === 'string' && v ? v : undefined);

export function eventSummary(event: Row | null | undefined, tiers: TierRow[], org?: Row | null): EventSummary | null {
  const name = event?.name;
  if (!event || !name) return null;
  const addr = event.venue_address && typeof event.venue_address === 'object' ? (event.venue_address as Row) : {};
  const cents = fromPriceCents(tiers);
  const currency = (str(event.currency) ?? 'USD').toUpperCase();
  return {
    id: event.id,
    name: String(name).slice(0, 200),
    date: dateLabel(str(event.starts_at), str(event.occurs_at_local)),
    startsAt: str(event.starts_at) ?? null,
    venue: (str(event.venue_name) ?? str(event.venue_location) ?? '').slice(0, 200) || null,
    city: str(addr.city),
    region: str(addr.region),
    street: str(addr.street),
    image: str(event.image_url),
    description: (str(event.description) ?? '').slice(0, 300),
    from: cents !== null ? money(cents, currency) : null,
    fromCents: cents,
    currency,
    orgName: str(org?.name),
  };
}

export function esc(v: unknown): string {
  return String(v)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;');
}

function tags(title: string, desc: string, url: string, image: string, ogType: string, noindex: boolean, extra = ''): string {
  const [t, d, u, img] = [esc(title), esc(desc), esc(url), esc(image)];
  const lines = [
    `<title>${t}</title>`,
    `<meta name="description" content="${d}" />`,
    `<meta name="robots" content="${noindex ? 'noindex, nofollow' : 'index, follow'}" />`,
    '<meta property="og:site_name" content="Exos" />',
    `<meta property="og:type" content="${ogType}" />`,
    `<meta property="og:title" content="${t}" />`,
    `<meta property="og:description" content="${d}" />`,
    `<meta property="og:url" content="${u}" />`,
    `<meta property="og:image" content="${img}" />`,
    '<meta property="og:locale" content="en_US" />',
    '<meta name="twitter:card" content="summary_large_image" />',
    `<meta name="twitter:title" content="${t}" />`,
    `<meta name="twitter:description" content="${d}" />`,
    `<meta name="twitter:image" content="${img}" />`,
    `<link rel="canonical" href="${u}" />`,
  ];
  if (extra) lines.push(extra);
  return lines.join('\n    ');
}

/** Per-event preview: '<name>' / 'Fri Oct 3 · 10 PM · Elsewhere · from $25 all-in'. */
export function eventTags(s: EventSummary, canonicalUrl: string, defaultImage: string, noindex = false): string {
  const price = s.from === 'Free' ? 'Free' : s.from ? `from ${s.from} all-in` : null;
  const desc = [s.date, s.venue, price].filter(Boolean).join(' · ') || s.description || 'Tickets on Exos';
  const image = s.image || defaultImage;
  const ld: Record<string, unknown> = {
    '@context': 'https://schema.org',
    '@type': 'Event',
    name: s.name,
    url: canonicalUrl,
    image: [image],
    eventStatus: 'https://schema.org/EventScheduled',
    eventAttendanceMode: 'https://schema.org/OfflineEventAttendanceMode',
  };
  if (s.startsAt) ld.startDate = s.startsAt;
  if (s.venue) {
    const loc: Record<string, unknown> = { '@type': 'Place', name: s.venue };
    const addr: Record<string, string> = {};
    if (s.street) addr.streetAddress = s.street;
    if (s.city) addr.addressLocality = s.city;
    if (s.region) addr.addressRegion = s.region;
    if (Object.keys(addr).length) loc.address = { ...addr, '@type': 'PostalAddress' };
    ld.location = loc;
  }
  if (s.orgName) ld.organizer = { '@type': 'Organization', name: s.orgName };
  if (s.fromCents !== null) {
    ld.offers = {
      '@type': 'Offer',
      url: canonicalUrl,
      price: (s.fromCents / 100).toFixed(2),
      priceCurrency: s.currency || 'USD',
      availability: 'https://schema.org/InStock',
    };
  }
  const raw = JSON.stringify(ld).replace(/</g, '\\u003c');
  const extra = noindex ? '' : `<script type="application/ld+json">${raw}</script>`;
  return tags(s.name, desc, canonicalUrl, image, 'event', noindex, extra);
}

export function orgTags(org: Row, canonicalUrl: string, defaultImage: string): string | null {
  const name = org?.name;
  if (!name) return null;
  const marketing = org.marketing && typeof org.marketing === 'object' ? (org.marketing as Row) : {};
  const theme = org.theme && typeof org.theme === 'object' ? (org.theme as Row) : {};
  const image = str(marketing.shareImageUrl) ?? str(theme.logoUrl) ?? defaultImage;
  const desc = (str(org.description) ?? `Upcoming events from ${name}.`).slice(0, 300);
  return tags(String(name).slice(0, 200), desc, canonicalUrl, image, 'website', false);
}

/** Swap the SSR_META block in the SPA shell for `tagBlock`; no-op on any miss. */
export function inject(shell: string, tagBlock: string | null | undefined): string {
  if (!tagBlock) return shell;
  const start = shell.indexOf(SSR_META_START);
  const end = shell.indexOf(SSR_META_END);
  if (start === -1 || end === -1 || end < start) return shell;
  return shell.slice(0, start) + tagBlock + shell.slice(end + SSR_META_END.length);
}

// ── Data ─────────────────────────────────────────────────────────────

/**
 * Reads the public views (exos_public_events / _tiers / _orgs). The server
 * backs it with supabase-js + the anon key; tests pass a fake.
 */
export type PublicReader = (
  table: 'exos_public_events' | 'exos_public_tiers' | 'exos_public_orgs',
  cols: string,
  filter: { col: string; val: string } | null,
  limit: number,
) => Promise<Row[]>;

const EVENT_COLS =
  'id,org_id,name,slug,description,occurs_at_local,starts_at,timezone,currency,venue_name,venue_location,venue_address,image_url';

/** Resolve a preview target against the public views and return the tag block, or null. */
export async function buildPreview(read: PublicReader, target: PreviewTarget, baseUrl: string): Promise<string | null> {
  let [kind, key] = target;
  const defaultImage = `${baseUrl}/bridge/icon-512.png`;

  if (kind === 'org') {
    const orgs = await read('exos_public_orgs', 'id,name,slug,theme,description,marketing', { col: 'slug', val: key }, 1);
    if (!orgs.length) return null;
    return orgTags(orgs[0], `${baseUrl}/bridge/o/${orgs[0].slug}`, defaultImage);
  }
  if (kind === 'checkout_tier') {
    const tiers = await read('exos_public_tiers', 'event_id', { col: 'id', val: key }, 1);
    if (!tiers.length) return null;
    kind = 'event';
    key = String(tiers[0].event_id);
  }
  const events = await read('exos_public_events', EVENT_COLS, { col: kind === 'event_slug' ? 'slug' : 'id', val: key }, 1);
  if (!events.length) return null;
  const ev = events[0];
  const tiers = await read('exos_public_tiers', 'price,price_schedule,exclusive_tax_percent', { col: 'event_id', val: String(ev.id) }, 50);
  const orgs = ev.org_id ? await read('exos_public_orgs', 'name', { col: 'id', val: String(ev.org_id) }, 1) : [];
  const s = eventSummary(ev, tiers as TierRow[], orgs[0] ?? null);
  if (!s) return null;
  // Checkout and promoter links preview the event but point search engines at
  // the event page, and promoter kits stay out of the index.
  return eventTags(s, `${baseUrl}/bridge/event/${ev.id}`, defaultImage, target[0] === 'promoter');
}

/**
 * sitemap.xml: every published event that hasn't ended (or, without an end,
 * didn't start more than a day ago) plus every organizer page.
 */
export async function buildSitemap(read: PublicReader, baseUrl: string, now: Date = new Date()): Promise<string> {
  const cutoff = now.getTime() - 86_400_000;
  const ts = (v: unknown) => (typeof v === 'string' && v ? parseInstant(v) : NaN);
  const urls: string[] = [];
  for (const ev of await read('exos_public_events', 'id,starts_at,ends_at', null, 5000)) {
    const end = ts(ev.ends_at);
    const when = Number.isNaN(end) ? ts(ev.starts_at) : end;
    if (!Number.isNaN(when) && when < cutoff) continue;
    urls.push(`${baseUrl}/bridge/event/${ev.id}`);
  }
  for (const org of await read('exos_public_orgs', 'slug', null, 5000)) {
    if (org.slug) urls.push(`${baseUrl}/bridge/o/${org.slug}`);
  }
  return (
    '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
    urls.map((u) => `  <url><loc>${esc(u)}</loc></url>\n`).join('') +
    '</urlset>\n'
  );
}
