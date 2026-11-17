#!/usr/bin/env node
// Waiting-room load test (docs/load-test.md): `npm run loadtest`.
//
// Drives the SQL hot paths of a big on-sale at stepped concurrency, the way
// PostgREST and exos-checkout call them: one transaction per request on a
// shared connection pool, with the request's role, JWT claims and headers set
// as GUCs (role, request.jwt.claims, request.headers). Each virtual user (VU)
// arrives at a random moment of the ramp, reads the event page (event +
// ticket types), joins the waiting room (token mint), polls with the
// server's suggested, jittered pace (--poll-scale multiplies it; 1 is real
// time) until admitted, then runs exos-checkout's SQL before Stripe: the queue
// check, the tier read, the last-call read, the purchase limit, the current
// price, the guest hold (with the queue token header) and the fee terms.
// Payment is stubbed: nothing calls Stripe, and the holds simply expire.
//
// Targets: the local scratch Postgres built by tests/exos/run_p0.sh (the
// default), or a Supabase STAGING BRANCH with LOADTEST_TARGET=staging. It
// refuses the shared prod project, always. It never runs in CI.
//
//   npm run loadtest -- --db exos_loadtest --steps 100,1000,5000,10000
//   LOADTEST_TARGET=staging LOADTEST_DATABASE_URL=postgres://... npm run loadtest -- --steps 100,1000
//
// Flags: --steps (VUs per step), --pool (connections, default 40: PostgREST's
// pool on a small instance), --ramp (seconds over which a step's VUs arrive,
// default 20), --rate (admits per minute, default 3000), --poll-scale
// (multiplies the server's poll pace; default 1 = real time), --max-step
// (seconds a step lasts; VUs still in line then are counted as in_line, not
// errors; default 90), --out (JSON results file).

import pg from 'pg';
import { performance } from 'node:perf_hooks';
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import os from 'node:os';

const PROD_REF = 'hzrizjeaxlqcxfrtczpq';

function args(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const [k, v] = a.includes('=') ? a.slice(2).split('=') : [a.slice(2), argv[++i]];
      out[k] = v;
    }
  }
  return out;
}
const A = args(process.argv.slice(2));
const STEPS = String(A.steps ?? '100,1000,5000,10000').split(',').map(Number).filter((n) => n > 0);
const POOL = Number(A.pool ?? 40);
const RAMP_S = Number(A.ramp ?? 20);
const RATE = Number(A.rate ?? 3000);
const POLL_SCALE = Number(A['poll-scale'] ?? 1);
const MAX_STEP_S = Number(A['max-step'] ?? 90);
const OUT = A.out ?? null;

// --- where ------------------------------------------------------------------
const target = process.env.LOADTEST_TARGET ?? 'local';
const url = process.env.LOADTEST_DATABASE_URL ?? null;
const conn = url
  ? { connectionString: url }
  : { host: process.env.PGHOST ?? '/tmp/pgrun', port: Number(process.env.PGPORT ?? 5433),
      user: process.env.PGUSER ?? 'postgres', database: A.db ?? process.env.PGDATABASE ?? 'exos_loadtest' };
const where = url ?? `${conn.host}:${conn.port}/${conn.database}`;
if (where.includes(PROD_REF)) {
  console.error('loadtest: refusing the shared prod project. Use a local database or a staging branch.');
  process.exit(2);
}
const local = !url || /@(localhost|127\.0\.0\.1|\[::1\])[:/]/.test(url) || /host=\/|%2F/.test(url);
if (!local && target !== 'staging') {
  console.error('loadtest: a remote database needs LOADTEST_TARGET=staging (a Supabase branch, never prod).');
  process.exit(2);
}
if (target === 'staging' && !/supabase\.(co|com)/.test(where)) {
  console.warn('loadtest: LOADTEST_TARGET=staging but the URL is not a Supabase host; continuing.');
}

const pool = new pg.Pool({ ...conn, max: POOL, idleTimeoutMillis: 30000, connectionTimeoutMillis: 120000 });

// --- one PostgREST-style request ----------------------------------------------
const CLAIMS = { anon: '{"role":"anon"}', service_role: '{"role":"service_role"}' };
let samples = new Map();   // op -> [ms...]
let errors = new Map();    // op -> count
let errorKinds = new Map();
function record(op, ms, ok, err) {
  if (!samples.has(op)) samples.set(op, []);
  samples.get(op).push(ms);
  if (!ok) {
    errors.set(op, (errors.get(op) ?? 0) + 1);
    const k = `${op}: ${String(err?.message ?? err).slice(0, 90)}`;
    errorKinds.set(k, (errorKinds.get(k) ?? 0) + 1);
  }
}
async function request(op, role, headers, sql, params) {
  const t0 = performance.now();
  let c;
  try {
    c = await pool.connect();
    await c.query('BEGIN');
    await c.query("SELECT set_config('role', $1, true), set_config('request.jwt.claims', $2, true), set_config('request.headers', $3, true)",
      [role, CLAIMS[role], JSON.stringify(headers)]);
    const r = await c.query(sql, params);
    await c.query('COMMIT');
    record(op, performance.now() - t0, true);
    return r.rows;
  } catch (e) {
    if (c) await c.query('ROLLBACK').catch(() => {});
    record(op, performance.now() - t0, false, e);
    throw e;
  } finally {
    c?.release();
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- fixture ------------------------------------------------------------------
const ORG = '7e570000-0000-4000-8000-000000000001';
const OWNER = '7e570000-0000-4000-8000-0000000000a1';
const EV = '7e570000-0000-4000-8000-0000000000e1';
const TIER = '7e570000-0000-4000-8000-0000000000c1';
async function admin(sql, params) {
  const c = await pool.connect();
  try { return (await c.query(sql, params)).rows; } finally { c.release(); }
}
async function setupStep(onSaleInS) {
  await admin(`DELETE FROM public.exos_cart_holds WHERE event_id = $1`, [EV]);
  await admin(`DELETE FROM public.exos_wroom_entries WHERE event_id = $1`, [EV]);
  await admin(`DELETE FROM public.exos_wroom_settings WHERE event_id = $1`, [EV]);
  await admin(`DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'wroom-ip:%'`);
  await admin(`INSERT INTO auth.users (id, email, email_confirmed_at) VALUES ($1, 'owner@loadtest.invalid', now()) ON CONFLICT (id) DO NOTHING`, [OWNER]);
  await admin(`INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES ($1, 'Load Test', 'load-test-org', $2) ON CONFLICT (id) DO NOTHING`, [ORG, OWNER]);
  await admin(`INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by, link_out)
               VALUES ($1, $2, 'Load Test Drop', 'load-test-drop', 'published', now() + interval '30 days', 'America/New_York', 1000000, $3, false)
               ON CONFLICT (id) DO NOTHING`, [EV, ORG, OWNER]);
  await admin(`INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sales_start, visibility)
               VALUES ($1, $2, 'GA', 25, 1000000, now(), 'public') ON CONFLICT (id) DO NOTHING`, [TIER, EV]);
  await admin(`UPDATE public.exos_ticket_tiers SET sales_start = now() + make_interval(secs => $2), sold = 0 WHERE id = $1`, [TIER, onSaleInS]);
  // The room: on, opens 15 minutes before (so the lobby is open now), RATE a minute.
  await admin(`INSERT INTO public.exos_wroom_settings (event_id, org_id, enabled, window_minutes, admit_per_minute, admission_minutes, idle_close_minutes, enabled_at)
               VALUES ($1, $2, true, 15, $3, 10, 30, now())`, [EV, ORG, RATE]);
  // Supabase grants the service role every public table; the scratch harness
  // doesn't, so give it the two exos-checkout reads (a no-op on a branch).
  await admin('GRANT SELECT ON public.exos_ticket_tiers, public.exos_events TO service_role');
  await admin('VACUUM ANALYZE public.exos_wroom_entries');
  await admin('VACUUM ANALYZE public.exos_cart_holds');
}

// --- one virtual user -----------------------------------------------------------
const PUBLIC_EVENT = `SELECT to_jsonb(e) - 'description_md' AS e FROM public.exos_public_events e WHERE e.id = $1`;
const PUBLIC_TIERS = `SELECT to_jsonb(t) AS t FROM public.exos_public_tiers t WHERE t.event_id = $1`;
function jitter(ms) { return ms * (0.75 + Math.random() * 0.5); }

async function vu(i, deadline, stepTag) {
  const ip = `10.${(i >> 16) & 255}.${(i >> 8) & 255}.${i & 255}`;
  const hdr = { 'cf-connecting-ip': ip };
  await sleep(Math.random() * RAMP_S * 1000);
  try {
    await request('event_read', 'anon', hdr, PUBLIC_EVENT, [EV]);
    await request('event_read', 'anon', hdr, PUBLIC_TIERS, [EV]);
    let s = (await request('token_mint', 'anon', hdr, 'SELECT public.exos_wroom_join($1, NULL) AS s', [EV]))[0].s;
    const token = s.token;
    while (s.state === 'busy') {
      await sleep(jitter(s.retry_after_ms ?? 5000) * POLL_SCALE);
      s = (await request('token_mint', 'anon', hdr, 'SELECT public.exos_wroom_join($1, NULL) AS s', [EV]))[0].s;
    }
    const tok = s.token ?? token;
    while (s.state !== 'admitted') {
      if (performance.now() > deadline) return 'in_line';
      if (s.state === 'off') break;
      await sleep(Math.max(200, jitter(s.poll_after_ms ?? 5000) * POLL_SCALE));
      s = (await request('poll', 'anon', hdr, 'SELECT public.exos_wroom_status($1, $2) AS s', [EV, tok]))[0].s;
    }
    // exos-checkout before Stripe (service role), the token in the body and the hold header.
    const t0 = performance.now();
    const email = `vu${i}.${stepTag}@loadtest.invalid`;
    const svc = { ...hdr, 'x-exos-queue': tok };
    await request('checkout_sql', 'service_role', hdr, 'SELECT public.exos_wroom_require($1, $2, $3, NULL, $4) AS ok', [EV, TIER, tok, email]);
    await request('checkout_sql', 'service_role', hdr,
      'SELECT t.id, t.price, t.capacity, t.sold, e.org_id, e.status FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id WHERE t.id = $1 AND t.event_id = $2', [TIER, EV]);
    await request('checkout_sql', 'service_role', hdr, 'SELECT * FROM public.exos_public_event_sale($1)', [EV]);
    await request('checkout_sql', 'service_role', hdr, 'SELECT public.exos_assert_purchase_limit_email($1, $2, 2)', [EV, email]);
    await request('checkout_sql', 'service_role', hdr, 'SELECT public.exos_tier_current_price($1)', [TIER]);
    await request('hold', 'service_role', svc, 'SELECT public.exos_create_guest_hold($1, $2, 2, $3, $4, NULL) AS h',
      [EV, TIER, email, randomUUID().replace(/-/g, '')]);
    await request('checkout_sql', 'service_role', hdr, 'SELECT public.exos_event_fee_terms($1, $2, 2)', [EV, TIER]);
    record('checkout_pre_stripe', performance.now() - t0, true);
    return 'held';
  } catch {
    return 'error';
  }
}

// --- report -------------------------------------------------------------------
function pct(sorted, p) {
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}
function summarize(stepVus, wallS, outcomes, extra) {
  const ops = ['event_read', 'token_mint', 'poll', 'checkout_sql', 'hold', 'checkout_pre_stripe'];
  const rows = ops.filter((op) => samples.has(op)).map((op) => {
    const a = samples.get(op).slice().sort((x, y) => x - y);
    const n = a.length;
    const e = errors.get(op) ?? 0;
    return { op, n, rps: +(n / wallS).toFixed(1), p50: +pct(a, 50).toFixed(1), p95: +pct(a, 95).toFixed(1),
      p99: +pct(a, 99).toFixed(1), max: +a[n - 1].toFixed(1), errors: e, error_rate: +(e / n * 100).toFixed(2) };
  });
  return { vus: stepVus, wall_s: +wallS.toFixed(1), outcomes, ...extra, ops: rows, error_kinds: Object.fromEntries(errorKinds) };
}

const results = [];
const machine = { cpus: os.cpus().length, cpu: os.cpus()[0]?.model, mem_gb: Math.round(os.totalmem() / 2 ** 30), node: process.version,
  pool: POOL, ramp_s: RAMP_S, rate_per_min: RATE, poll_scale: POLL_SCALE, target: url ? (local ? 'local url' : target) : 'local socket' };
const [{ v: pgv }] = await admin('SELECT version() AS v');
machine.postgres = pgv.split(' on ')[0];
console.log(`loadtest: ${where} (${machine.target}); ${JSON.stringify(machine)}`);

for (const n of STEPS) {
  samples = new Map(); errors = new Map(); errorKinds = new Map();
  // The on-sale lands halfway through the ramp: half the crowd is early (random draw), half late.
  await setupStep(RAMP_S / 2);
  const t0 = performance.now();
  const deadline = t0 + MAX_STEP_S * 1000;
  const tag = Date.now().toString(36);
  const outs = await Promise.all(Array.from({ length: n }, (_, i) => vu(i, deadline, tag)));
  const wall = (performance.now() - t0) / 1000;
  const outcomes = outs.reduce((m, o) => ({ ...m, [o]: (m[o] ?? 0) + 1 }), {});
  const [st] = await admin(`SELECT count(*) FILTER (WHERE used_at IS NOT NULL) AS used, count(*) AS entries,
                                   (SELECT coalesce(sum(quantity), 0) FROM public.exos_cart_holds WHERE event_id = $1 AND status = 'active') AS held
                              FROM public.exos_wroom_entries WHERE event_id = $1`, [EV]);
  const r = summarize(n, wall, outcomes, { entries: Number(st.entries), admissions_used: Number(st.used), tickets_held: Number(st.held) });
  results.push(r);
  console.log(`\n== ${n} VUs: ${r.wall_s}s, ${JSON.stringify(outcomes)}, entries ${r.entries}, holds for ${r.tickets_held} tickets`);
  console.log('op                   n       rps     p50 ms  p95 ms  p99 ms  max ms  err %');
  for (const o of r.ops) {
    console.log(`${o.op.padEnd(20)} ${String(o.n).padStart(7)} ${String(o.rps).padStart(8)} ${String(o.p50).padStart(7)} ${String(o.p95).padStart(7)} ${String(o.p99).padStart(7)} ${String(o.max).padStart(7)} ${String(o.error_rate).padStart(6)}`);
  }
  if (errorKinds.size) console.log('errors:', Object.fromEntries(errorKinds));
}

// Leave nothing behind but the fixture rows (holds and the queue are cleared).
await admin(`DELETE FROM public.exos_cart_holds WHERE event_id = $1`, [EV]);
await admin(`DELETE FROM public.exos_wroom_entries WHERE event_id = $1`, [EV]);
if (OUT) writeFileSync(OUT, JSON.stringify({ machine, results }, null, 2));
await pool.end();
