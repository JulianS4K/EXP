// ---------------------------------------------------------------------------
// Opendate coverage: how every Opendate API v2 endpoint maps onto Exos.
//
//   node scripts/check-opendate-coverage.mjs           check (exit 1 on any error)
//   node scripts/check-opendate-coverage.mjs --write   check, then regenerate
//                                                      docs/opendate-coverage.md
//   node scripts/check-opendate-coverage.mjs --catalog <file.tsv>
//        also compare against an Opendate catalog export (category, method,
//        path as the first three tab-separated columns)
//
// docs/opendate-coverage.json holds one entry per Opendate endpoint (455):
// { category, method, path, status, exos, reason }. Only the category, method
// and path are kept from Opendate's catalog, never its descriptions.
//
//   status  route           an Exos partner-API route does the same; `exos`
//                           is "<METHOD> /v1/<path>" and must be a row of the
//                           route table that docs/api documents
//           equivalent      Exos does it another way (another route shape, a
//                           signed-in RPC, an edge function, the dashboard)
//           not_applicable  doesn't apply to Exos
//           planned         not built yet
//
// Every "<METHOD> /v1/…" named in `exos`, whatever the status, must be a real
// route, so a renamed route can't leave the table pointing nowhere. Admin
// categories (Opendate's back office) are never `route`. The summary page,
// docs/opendate-coverage.md, is generated from the JSON and must be current.
// ---------------------------------------------------------------------------

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(here, '..');
export const EXPECTED_ENDPOINTS = 455;
export const STATUSES = ['route', 'equivalent', 'not_applicable', 'planned'];
const METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
const ROUTES_FILE = path.join('supabase', 'functions', '_shared', 'api', 'routes.ts');
const JSON_FILE = path.join('docs', 'opendate-coverage.json');
const MD_FILE = path.join('docs', 'opendate-coverage.md');

/** "/v1/events/:id?x=" or "/v1/events/{id}" -> "/events/:" (no version, no query, params unnamed). */
export function normPath(p) {
  return p.replace(/[?#].*$/, '').replace(/^\/v1(?=\/)/, '').replace(/:[A-Za-z_]\w*|\{[^}]+\}/g, ':').replace(/\/+$/, '') || '/';
}

/** The route table's rows (id, method, path, aliases), read from routes.ts's source. */
export function readRoutes(root = ROOT) {
  const src = fs.readFileSync(path.join(root, ROUTES_FILE), 'utf8');
  const rows = [];
  for (const m of src.matchAll(/\{\s*id:\s*'([^']+)'([^}]*)\}/g)) {
    const body = m[2];
    const method = /method:\s*'([A-Z]+)'/.exec(body)?.[1];
    const p = /path:\s*'([^']+)'/.exec(body)?.[1];
    if (!method || !p) continue;
    const aliases = [...(/aliases:\s*\[([^\]]*)\]/.exec(body)?.[1] ?? '').matchAll(/'([^']+)'/g)].map((a) => a[1]);
    rows.push({ id: m[1], method, path: p, aliases });
  }
  return rows;
}

/** Documented endpoints of docs/api/*.json as "METHOD /path" keys. */
export function readDocumented(root = ROOT) {
  const dir = path.join(root, 'docs', 'api');
  const keys = new Set();
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.json') || f === '_meta.json') continue;
    for (const e of JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')).endpoints ?? []) {
      keys.add(`${e.method} ${normPath(e.path)}`);
    }
  }
  return keys;
}

/** "GET /v1/events/:id" tokens named in a free-text `exos` field. */
export function namedRoutes(text) {
  return [...String(text).matchAll(/\b(GET|POST|PUT|PATCH|DELETE) (\/v1\/[^\s,;()+]*)/g)].map((m) => ({ method: m[1], path: m[2] }));
}

const isAdmin = (category) => category.startsWith('admin');

/** Check the coverage table; returns { errors, coverage, routes, used }. */
export function check({ root = ROOT, catalog = null } = {}) {
  const errors = [];
  const coverage = JSON.parse(fs.readFileSync(path.join(root, JSON_FILE), 'utf8'));
  const entries = coverage.endpoints;
  const routes = readRoutes(root);
  const documented = readDocumented(root);
  const byKey = new Map();
  for (const r of routes) {
    for (const p of [r.path, ...r.aliases]) byKey.set(`${r.method} ${normPath(p)}`, r);
  }
  const used = new Set();

  if (!Array.isArray(entries)) return { errors: ['endpoints must be an array'], coverage, routes, used };
  if (entries.length !== EXPECTED_ENDPOINTS) {
    errors.push(`${entries.length} endpoints, expected ${EXPECTED_ENDPOINTS} (one per Opendate endpoint)`);
  }
  entries.forEach((e, i) => {
    const at = `#${i} ${e?.method} ${e?.path}`;
    for (const k of ['category', 'method', 'path', 'status', 'exos']) {
      if (typeof e?.[k] !== 'string' || !e[k].trim()) errors.push(`${at}: missing ${k}`);
    }
    if (typeof e?.reason !== 'string') errors.push(`${at}: missing reason`);
    const extra = Object.keys(e ?? {}).filter((k) => !['category', 'method', 'path', 'status', 'exos', 'reason'].includes(k));
    if (extra.length) errors.push(`${at}: unexpected keys ${extra.join(', ')} (only category, method and path come from Opendate)`);
    if (!METHODS.includes(e?.method)) errors.push(`${at}: bad method`);
    if (!STATUSES.includes(e?.status)) errors.push(`${at}: status must be one of ${STATUSES.join(', ')}`);
    if (e?.status !== 'route' && !String(e?.reason ?? '').trim()) errors.push(`${at}: ${e?.status} needs a reason`);
    if (isAdmin(String(e?.category ?? '')) && e?.status === 'route') {
      errors.push(`${at}: an admin endpoint is equivalent, not_applicable or planned, never route`);
    }
    const named = namedRoutes(e?.exos ?? '');
    if (e?.status === 'route') {
      const m = /^(GET|POST|PUT|PATCH|DELETE) (\/v1\/\S+)$/.exec(e.exos ?? '');
      if (!m) errors.push(`${at}: a route entry's exos is "<METHOD> /v1/<path>", got "${e.exos}"`);
    }
    for (const n of named) {
      const key = `${n.method} ${normPath(n.path)}`;
      const r = byKey.get(key);
      if (!r) { errors.push(`${at}: names ${n.method} ${n.path}, which is not in the route table`); continue; }
      used.add(r.id);
      if (!documented.has(`${r.method} ${normPath(r.path)}`)) errors.push(`${at}: ${n.method} ${n.path} (${r.id}) is not documented in docs/api`);
    }
  });

  // Every catalog endpoint once (a multiset: Opendate lists POST /oauth/token twice).
  const counts = new Map();
  for (const e of entries) {
    const k = `${e.category}\t${e.method}\t${e.path}`;
    counts.set(k, (counts.get(k) ?? 0) + 1);
  }
  if (catalog) {
    const want = new Map();
    for (const line of fs.readFileSync(catalog, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      const [c, m, p] = line.split('\t');
      const k = `${c}\t${m}\t${p}`;
      want.set(k, (want.get(k) ?? 0) + 1);
    }
    for (const [k, n] of want) {
      const have = counts.get(k) ?? 0;
      if (have < n) errors.push(`missing from the table: ${k.replace(/\t/g, ' ')}${n > 1 ? ` (${n - have} of ${n})` : ''}`);
    }
    for (const [k, n] of counts) {
      if (n > (want.get(k) ?? 0)) errors.push(`not in the Opendate catalog: ${k.replace(/\t/g, ' ')}`);
    }
  }
  return { errors, coverage, routes, used };
}

/** docs/opendate-coverage.md, generated. */
export function renderMarkdown({ coverage, routes, used }) {
  const entries = coverage.endpoints;
  const cats = new Map();
  for (const e of entries) {
    if (!cats.has(e.category)) cats.set(e.category, Object.fromEntries(STATUSES.map((s) => [s, 0])));
    cats.get(e.category)[e.status]++;
  }
  const total = Object.fromEntries(STATUSES.map((s) => [s, entries.filter((e) => e.status === s).length]));
  const covered = total.route + total.equivalent;
  const pct = (n) => `${Math.round((n / entries.length) * 1000) / 10}%`;
  const beyond = routes.filter((r) => !used.has(r.id));
  const row = (name, c) => `| ${name} | ${STATUSES.reduce((a, s) => a + c[s], 0)} | ${c.route} | ${c.equivalent} | ${c.not_applicable} | ${c.planned} |`;
  const groups = [['Partner and public API', (c) => !c.startsWith('admin')], ["Opendate's back office (admin)", (c) => c.startsWith('admin')]];
  const out = [
    '# Opendate coverage',
    '',
    '<!-- Generated by scripts/check-opendate-coverage.mjs --write from docs/opendate-coverage.json. Do not edit by hand. -->',
    '',
    `How each of Opendate's ${entries.length} API v2 endpoints maps onto Exos. The per-endpoint table, with the`,
    'Exos route or mechanism and the reason, is `docs/opendate-coverage.json`; CI checks it',
    '(`node scripts/check-opendate-coverage.mjs`) so every endpoint is accounted for and every Exos route it names',
    'exists and is documented in `docs/api`.',
    '',
    '- **route**: an Exos partner-API route does the same.',
    '- **equivalent**: Exos does it another way: another route shape, a signed-in RPC, an edge function or the dashboard.',
    "- **not_applicable**: doesn't apply to Exos (platform-internal, another vendor's product, or a deliberate no).",
    '- **planned**: not built yet.',
    '',
    '## Totals',
    '',
    '| | Endpoints | Share |',
    '|---|---:|---:|',
    `| route | ${total.route} | ${pct(total.route)} |`,
    `| equivalent | ${total.equivalent} | ${pct(total.equivalent)} |`,
    `| **covered (route + equivalent)** | **${covered}** | **${pct(covered)}** |`,
    `| not_applicable | ${total.not_applicable} | ${pct(total.not_applicable)} |`,
    `| planned | ${total.planned} | ${pct(total.planned)} |`,
    `| **Opendate endpoints** | **${entries.length}** | |`,
    '',
    `Exos routes beyond Opendate: **${beyond.length}** of the ${routes.length} rows in the route table`,
    "aren't named by any entry (Exos-only features, or finer-grained routes than Opendate's).",
    '',
  ];
  for (const [title, pick] of groups) {
    out.push(`## ${title}`, '', '| Category | Endpoints | route | equivalent | not_applicable | planned |', '|---|---:|---:|---:|---:|---:|');
    for (const [name, c] of cats) if (pick(name)) out.push(row(name, c));
    out.push('');
  }
  out.push('## Planned', '', '| Category | Endpoint | Note |', '|---|---|---|');
  for (const e of entries.filter((x) => x.status === 'planned')) {
    out.push(`| ${e.category} | \`${e.method} ${e.path}\` | ${e.reason.replace(/\|/g, '\\|')} |`);
  }
  out.push('');
  return out.join('\n');
}

function main(argv) {
  const ci = argv.indexOf('--catalog');
  const res = check({ catalog: ci >= 0 ? argv[ci + 1] : null });
  const md = renderMarkdown(res);
  const mdPath = path.join(ROOT, MD_FILE);
  if (argv.includes('--write')) {
    fs.writeFileSync(mdPath, md);
  } else if (!fs.existsSync(mdPath) || fs.readFileSync(mdPath, 'utf8') !== md) {
    res.errors.push(`${MD_FILE} is out of date: run node scripts/check-opendate-coverage.mjs --write`);
  }
  if (res.errors.length) {
    for (const e of res.errors) console.error(`opendate-coverage: ${e}`);
    process.exit(1);
  }
  const n = res.coverage.endpoints.length;
  const covered = res.coverage.endpoints.filter((e) => e.status === 'route' || e.status === 'equivalent').length;
  console.log(`opendate-coverage: ${n} endpoints, ${covered} covered (route + equivalent), ${res.routes.length - res.used.size} Exos routes beyond Opendate`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
