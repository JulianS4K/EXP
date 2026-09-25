// Tiny PostgREST/RPC stand-in for the smoke tests: eq./in. filters, object
// responses when supabase-js asks for a single row, RPCs from a table.
export const EV = '11111111-1111-4111-8111-111111111111';
export const TIER = '22222222-2222-4222-8222-222222222222';
export const TIER2 = '22222222-2222-4222-8222-333333333333';
export const HIDDEN = '22222222-2222-4222-8222-444444444444';
export const ADDON = '33333333-3333-4333-8333-333333333333';
export const ORG = '44444444-4444-4444-8444-444444444444';
export const TOKEN = '55555555-5555-4555-8555-555555555555';
const future = new Date(Date.now() + 7 * 864e5).toISOString();

export const tables = {
  exos_public_events: [{
    id: EV, org_id: ORG, name: 'Fall Party', slug: 'fall-party', description: 'Big night.',
    occurs_at_local: future.slice(0, 19), starts_at: future, doors_at: null, ends_at: null,
    timezone: 'America/New_York', currency: 'USD', venue_name: 'Elsewhere', venue_location: 'Elsewhere',
    venue_address: { street: '599 Johnson Ave', city: 'Brooklyn', region: 'NY' }, primary_performer_name: 'DJ Kay',
    performer_names: ['DJ Kay'], event_type: 'concert', category: 'music', genres: [], subgenres: [],
    image_url: null, branding: {}, purchase_limits: {}, total_tickets: 0, tickets_sold: 0,
    artist_links: {}, series_id: null, series_index: null,
  }],
  exos_public_tiers: [
    { id: TIER, event_id: EV, name: 'GA', description: '', price: 20, capacity: 100, sold: 0, ticket_type: 'paid',
      sales_start: null, sales_end: null, sort_order: 0, price_schedule: null, exclusive_tax_percent: 0 },
    { id: TIER2, event_id: EV, name: 'VIP', description: '', price: 50, capacity: 20, sold: 0, ticket_type: 'paid',
      sales_start: null, sales_end: null, sort_order: 1, price_schedule: null, exclusive_tax_percent: 0 },
  ],
  exos_public_addons: [
    { id: ADDON, event_id: EV, name: 'Poster', description: '', price: 5, capacity: 10, sold: 0,
      max_per_order: 4, image_url: null, sort_order: 0, exclusive_tax_percent: 0 },
  ],
  exos_public_orgs: [{ id: ORG, name: 'Brooklyn Nights', slug: 'bk-nights', theme: {}, description: 'Parties.', followers_count: 0, marketing: {} }],
  exos_public_event_geo: [],
};

export const rpcs = {
  exos_public_promoter: (b) => b.p_code === 'dj-kay' && b.p_org_slug === 'bk-nights'
    ? { promoter: { name: 'DJ Kay', code: 'dj-kay' }, org: { id: ORG, name: 'Brooklyn Nights', slug: 'bk-nights' } } : null,
  exos_promoter_kit: (b) => b.p_token === TOKEN ? {
    promoter: { name: 'DJ Kay', code: 'dj-kay' }, org: { id: ORG, name: 'Brooklyn Nights', slug: 'bk-nights' },
    events: [{ event_id: EV, name: 'Fall Party', starts_at: future, tickets: 7, gross: 140, currency: 'USD' }],
  } : null,
  exos_check_voucher: (b) => [b.p_code === 'PRESALE'
    ? { is_valid: true, voucher_id: 'v1', restrict_tier_id: HIDDEN, can_bypass: false, override_price: null, reason: null }
    : { is_valid: false, voucher_id: null, restrict_tier_id: null, can_bypass: false, override_price: null, reason: 'invalid' }],
  exos_voucher_tier: (b) => b.p_code === 'PRESALE' ? [{ id: HIDDEN, event_id: EV, name: 'Presale', description: '', price: 15,
    capacity: 50, sold: 0, ticket_type: 'paid', sales_start: null, sales_end: null, sort_order: 2, price_schedule: null,
    exclusive_tax_percent: 0 }] : [],
};

function filterRows(rows, params) {
  let out = rows;
  for (const [k, v] of params) {
    if (['select', 'order', 'limit', 'offset'].includes(k)) continue;
    if (v.startsWith('eq.')) out = out.filter((r) => String(r[k]) === v.slice(3));
    else if (v.startsWith('in.(')) {
      const vals = v.slice(4, -1).split(',').map((x) => x.replace(/^"|"$/g, ''));
      out = out.filter((r) => vals.includes(String(r[k])));
    }
  }
  return out;
}

export async function handle(route, log) {
  const req = route.request();
  const url = new URL(req.url());
  const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
  if (url.pathname.startsWith('/auth/v1/')) return json({}, 401);
  if (url.pathname.startsWith('/rest/v1/rpc/')) {
    const fn = url.pathname.split('/').pop();
    const body = req.postDataJSON?.() ?? {};
    log.push(`rpc ${fn}`);
    const f = rpcs[fn];
    return f ? json(f(body)) : json({ message: `no mock for rpc ${fn}` }, 404);
  }
  if (url.pathname.startsWith('/rest/v1/')) {
    const table = url.pathname.split('/').pop();
    log.push(`get ${table}${url.search}`);
    const rows = filterRows(tables[table] ?? [], url.searchParams);
    const single = (req.headers()['accept'] || '').includes('vnd.pgrst.object');
    if (single) return rows.length ? json(rows[0]) : json({ code: 'PGRST116', message: 'no rows' }, 406);
    return json(rows);
  }
  if (url.pathname.startsWith('/functions/v1/')) { log.push(`fn ${url.pathname}`); return json({ ok: true }); }
  return json({ message: 'unmocked' }, 404);
}
