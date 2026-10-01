// Tiny PostgREST/RPC stand-in for the smoke tests: eq./in. filters, object
// responses when supabase-js asks for a single row, RPCs from a table.
export const EV = '11111111-1111-4111-8111-111111111111';
export const TIER = '22222222-2222-4222-8222-222222222222';
export const TIER2 = '22222222-2222-4222-8222-333333333333';
export const HIDDEN = '22222222-2222-4222-8222-444444444444';
export const ADDON = '33333333-3333-4333-8333-333333333333';
export const ORG = '44444444-4444-4444-8444-444444444444';
export const TOKEN = '55555555-5555-4555-8555-555555555555';
// The signed-in test user (smoke.mjs SESSION) and their ticket.
export const UID = '66666666-6666-4666-8666-666666666666';
export const TICKET = '77777777-7777-4777-8777-777777777777';
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
    // Store page content (mig 20260929120000); the markdown carries an XSS attempt.
    summary: 'Four rooms of house till late.', lineup: [{ name: 'DJ Kay', role: 'headliner', set_at: '23:30', bio: 'Brooklyn house.' }],
    description_md: '**Big** night. [bad](javascript:window.__xss=1) <img src=x onerror="window.__xss=1">',
    faq: [{ q: 'Is there a coat check?', a: 'Yes, $3.' }], gallery: [], video_url: null,
    min_age: 21, refund_policy: 'until_7d', policy_notes: 'No re-entry.',
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
  exos_public_orgs: [{ id: ORG, name: 'Brooklyn Nights', slug: 'bk-nights', theme: {}, description: 'Parties.', followers_count: 0,
    marketing: { socials: { instagram: 'https://instagram.com/bknights', x: '@bknights' } } }],
  exos_public_event_geo: [],
};

export const rpcs = {
  exos_public_promoter: (b) => b.p_code === 'dj-kay' && b.p_org_slug === 'bk-nights'
    ? { promoter: { name: 'DJ Kay', code: 'dj-kay', socials: { instagram: 'dj.kay' } }, org: { id: ORG, name: 'Brooklyn Nights', slug: 'bk-nights' } } : null,
  exos_promoter_kit: (b) => b.p_token === TOKEN ? {
    promoter: { name: 'DJ Kay', code: 'dj-kay', socials: { instagram: 'dj.kay' }, allow_tagging: true },
    org: { id: ORG, name: 'Brooklyn Nights', slug: 'bk-nights' },
    events: [{ event_id: EV, name: 'Fall Party', starts_at: future, tickets: 7, gross: 140, currency: 'USD' }],
  } : null,
  exos_promoter_set_socials: (b) => b.p_token === TOKEN
    ? { socials: b.p_socials, allow_tagging: b.p_allow_tagging } : null,
  exos_check_voucher: (b) => [b.p_code === 'PRESALE'
    ? { is_valid: true, voucher_id: 'v1', restrict_tier_id: HIDDEN, can_bypass: false, override_price: null, reason: null }
    : { is_valid: false, voucher_id: null, restrict_tier_id: null, can_bypass: false, override_price: null, reason: 'invalid' }],
  exos_voucher_tier: (b) => b.p_code === 'PRESALE' ? [{ id: HIDDEN, event_id: EV, name: 'Presale', description: '', price: 15,
    capacity: 50, sold: 0, ticket_type: 'paid', sales_start: null, sales_end: null, sort_order: 2, price_schedule: null,
    exclusive_tax_percent: 0 }] : [],
};

// Signed-in fixtures: the user owns ORG (org dashboards, settings, report).
const created = '2026-09-01T12:00:00Z';
export const ORG_ROW = {
  id: ORG, name: 'Brooklyn Nights', slug: 'bk-nights', owner_uid: UID, created_at: created, updated_at: created,
  description: 'Parties.', followers_count: 0, country: 'US', currency: 'USD', comp_budget: null, theme: {}, marketing: {},
};
// The private exos_events row (staff read) behind the public event.
export const EVENT_ROW = {
  ...tables.exos_public_events[0], status: 'published', created_by: UID, total_tickets: 120, tickets_sold: 0,
};
export const ownerTables = {
  exos_orgs: [ORG_ROW],
  // PostgREST embeds (org:exos_orgs(*)) are stored on the row.
  exos_org_memberships: [{ id: 'm1', org_id: ORG, user_id: UID, role: 'owner', disabled: false, created_at: created, added_by: UID, org: ORG_ROW }],
  exos_events: [EVENT_ROW],
  exos_ticket_tiers: [],
};

// Columns of the tables and views the money / marketing screens read, as the
// migrations define them (supabase/migrations). A select or filter naming a
// column that isn't here answers like PostgREST does (400, 42703), so a query
// drifting from the real schema fails the smoke test instead of passing on a
// forgiving mock. Tables not listed here aren't checked.
const cols = (s) => s.split(/\s+/).filter(Boolean);
export const schema = {
  // 20260523170000 + addons, vouchers, tax, attribution, webhook claim, guest, checkout records.
  exos_checkout_sessions: cols(`session_id event_id tier_id org_id buyer_uid buyer_email quantity amount_cents currency status
    ticket_ids payment_intent failure_reason created_at fulfilled_at addons voucher_id tax_cents promoter_id attribution
    reconcile_attempts reconcile_checked_at reconcile_next_at reconcile_done_at reconcile_note dispute_id dispute_status
    disputed_at dispute_closed_at guest ad_ids consent_marketing client_ip_hash user_agent application_fee_cents
    exos_fee_cents card_fee_est_cents fee_bps fee_free`),
  // View, 20260929131000.
  exos_order_money: cols(`session_id org_id event_id status currency created_at fulfilled_at gross_cents tax_cents
    application_fee_cents exos_fee_cents card_fee_est_cents card_fee_actual_cents fee_bps fee_free organizer_net_cents
    platform_net_cents refunded_cents payment_intent transfer_id balance_txn_id`),
  // View, 20260929070000.
  exos_marketplace_order_money: cols(`order_id org_id event_id channel external_order_id quantity currency proceeds exos_fee
    organizer_net received reported paid_amount payout_status clawback_amount state`),
  // 20260926192000 + fees, sale note, attention.
  exos_marketplace_orders: cols(`id channel external_order_id external_event_id external_listing_id distribution_listing_id
    event_id org_id tier_id quantity buyer_email proceeds currency sale_status status attention_reason ticket_ids transfer_ids
    delivery_plan confirm_by ship_by sold_at raw created_at updated_at exos_fee organizer_net sale_note handled_at handled_by
    handled_reason handled_note links_resent_at links_resent_by`),
  // 20260926020000.
  exos_promoter_commissions: cols(`id org_id promoter_id event_id ticket_id currency gross_cents base_cents rate_bps flat_cents
    terms_source commission_cents status accrued_at reversed_at reversed_reason payout_id paid_at recovered_payout_id updated_at`),
  // 20260929070000.
  exos_org_payouts: cols('id org_id currency amount status stripe_transfer_id idempotency_key error created_at updated_at sent_at'),
  exos_org_payout_lines: cols('id payout_id org_id order_id kind amount created_at'),
  // View, 20261001100000 (exos_invoices + credited amounts).
  exos_invoice_totals: cols(`id org_id event_id number session_id buyer_id buyer_email currency subtotal_cents tax_cents
    total_cents issued_at refunded_cents refunded_tax_cents net_cents credit_notes status`),
  // 20261001100000.
  exos_org_legal: cols('org_id legal_name legal_address tax_id invoice_footer updated_at updated_by'),
  // 20261001101000.
  exos_disputes: cols(`id org_id event_id session_id payment_intent charge_id dispute_id amount_cents fee_cents currency
    reason status evidence_due_by evidence_submitted livemode created_at updated_at closed_at last_event_id
    recovery_status recovery_candidate_cents raw`),
  // Only the embedded column the payouts page asks for is checked.
  exos_events: null,
};

// Split a PostgREST select on top-level commas: "a, b, x:t(c, d)".
function splitTop(sel) {
  const out = []; let depth = 0; let cur = '';
  for (const ch of sel) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; } else cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

/** Columns in a select (embeds checked against their own table) not in the schema. */
export function unknownColumns(table, select, filters = []) {
  const known = schema[table];
  const bad = [];
  for (const part of splitTop(select || '*')) {
    const embed = part.match(/^(?:(\w+):)?(\w+)(?:!\w+)?\((.*)\)$/s);
    if (embed) { bad.push(...unknownColumns(embed[2], embed[3]).map((c) => `${embed[2]}.${c}`)); continue; }
    const col = part.replace(/^\w+:/, '').replace(/::\w+$/, '');
    if (known && col !== '*' && !known.includes(col)) bad.push(col);
  }
  if (known) for (const f of filters) if (!known.includes(f)) bad.push(f);
  return bad;
}

function filterRows(rows, params) {
  let out = rows;
  for (const [k, v] of params) {
    if (['select', 'order', 'limit', 'offset', 'on_conflict', 'columns'].includes(k)) continue;
    if (v.startsWith('eq.')) out = out.filter((r) => String(r[k]) === v.slice(3));
    else if (v.startsWith('neq.')) out = out.filter((r) => String(r[k]) !== v.slice(4));
    else if (v === 'is.null') out = out.filter((r) => r[k] == null);
    else if (v.startsWith('in.(')) {
      const vals = v.slice(4, -1).split(',').map((x) => x.replace(/^"|"$/g, ''));
      out = out.filter((r) => vals.includes(String(r[k])));
    }
  }
  return out;
}

// `over` (per test) adds or replaces tables, RPCs and edge-function answers:
//   { tables: { name: rows }, rpcs: { name: (body) => data }, fns: { 'exos-wallet/pass': (body) => ({ status, body }) } }
// An RPC mock may return { __status, __body } to answer with an error.
export async function handle(route, log, over = {}) {
  const req = route.request();
  const url = new URL(req.url());
  const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
  if (url.pathname.startsWith('/auth/v1/')) return json({}, 401);
  if (url.pathname.startsWith('/rest/v1/rpc/')) {
    const fn = url.pathname.split('/').pop();
    const body = req.postDataJSON?.() ?? {};
    log.push(`rpc ${fn} ${JSON.stringify(body)}`);
    const f = over.rpcs?.[fn] ?? rpcs[fn];
    if (!f) return json({ message: `no mock for rpc ${fn}` }, 404);
    const out = f(body);
    return out && out.__status ? json(out.__body ?? {}, out.__status) : json(out);
  }
  if (url.pathname.startsWith('/rest/v1/')) {
    const table = url.pathname.split('/').pop();
    log.push(`${req.method()} ${table}${url.search}${req.method() === 'GET' ? '' : ' ' + (req.postData() ?? '')}`);
    const filters = [...url.searchParams.keys()].filter((k) => !['select', 'order', 'limit', 'offset', 'on_conflict', 'columns'].includes(k));
    const bad = req.method() === 'GET' ? unknownColumns(table, url.searchParams.get('select'), filters) : [];
    if (bad.length) return json({ code: '42703', message: `column ${table}.${bad[0]} does not exist` }, 400);
    const source = over.tables?.[table] ?? tables[table];
    if (source && source.__status) return json(source.__body ?? {}, source.__status);
    let rows = filterRows(source ?? [], url.searchParams);
    // .range(): offset/limit (paged reads stop on a short page).
    const offset = Number(url.searchParams.get('offset') || 0);
    const limit = url.searchParams.get('limit');
    if (offset || limit) rows = rows.slice(offset, limit ? offset + Number(limit) : undefined);
    const single = (req.headers()['accept'] || '').includes('vnd.pgrst.object');
    if (single) return rows.length ? json(rows[0]) : json({ code: 'PGRST116', message: 'no rows' }, 406);
    return json(rows);
  }
  if (url.pathname.startsWith('/functions/v1/')) {
    const name = url.pathname.slice('/functions/v1/'.length);
    log.push(`fn ${name} ${req.postData() ?? ''}`);
    const f = over.fns?.[name];
    if (f) {
      const out = f(req.postDataJSON?.() ?? {});
      return json(out.body ?? {}, out.status ?? 200);
    }
    return json({ ok: true });
  }
  return json({ message: 'unmocked' }, 404);
}
