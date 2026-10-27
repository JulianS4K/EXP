// ---------------------------------------------------------------------------
// Partner API reference: validate docs/api/*.json and bundle it for /developers.
// docs/api-reference.md.
//
//   node scripts/api-spec.mjs           validate, then write public/api-spec.json
//                                       and public/openapi.json
//   node scripts/api-spec.mjs --check   validate only (exit 1 on any error)
//   node scripts/api-spec.mjs --out d   write the two files into d instead
//
// Sources:
//   docs/api/_meta.json   global meta: title, version, base_url, description,
//                         authentication, pagination, rate_limiting,
//                         error_format, error_codes, webhooks?
//   docs/api/<file>.json  one category: { file, name, description, group?,
//                         order?, endpoints: [{ id, method, path, summary,
//                         description?, auth, scope, parameters[],
//                         responses[], request_example? }] }
//
// Every docs/api/*.json except _meta.json is a category, picked up
// automatically. Paths are as the client calls them, relative to base_url
// (the exos-api function): /v1/events. `scope` is the one scope the route
// needs (a name from SCOPES in supabase/functions/_shared/api/scopes.ts), or
// null for a route any valid key may call.
//
// The page at /developers (src/views/Developers.tsx) renders
// public/api-spec.json; public/openapi.json is the same spec as OpenAPI 3.1
// for Postman / Insomnia. Both are generated (gitignored): the Vite plugin in
// vite.config.ts runs this for any `vite build` and for the dev server.
// src/lib/apiReference.test.ts checks the spec against the route table
// (supabase/functions/_shared/api/routes.ts), so a route can't ship
// undocumented and a documented path can't be missing from the API.
//
// Adapted from the Firebase build (Exos-Bridge PR #1, scripts/api-spec.mjs).
// ---------------------------------------------------------------------------

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
export const AUTH = ['api_key'];
export const LOCATIONS = ['path', 'query', 'body', 'header'];
const ID_RE = /^[a-z0-9][a-z0-9-]{0,79}$/;
const FILE_RE = /^[a-z0-9][a-z0-9-]*$/;
const CATEGORY_KEYS = new Set(['file', 'name', 'description', 'group', 'order', 'endpoints']);
const ENDPOINT_KEYS = new Set(['id', 'method', 'path', 'summary', 'description', 'auth', 'scope', 'parameters', 'responses', 'request_example', 'deprecated']);
const PARAM_KEYS = new Set(['name', 'location', 'type', 'required', 'description', 'example', 'enum', 'default']);
const RESPONSE_KEYS = new Set(['status', 'description', 'example', 'headers', 'content_type']);
const DEFAULT_ORDER = 65;
const DEFAULT_GROUP = 'Partner API';

const here = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(here, '..');
const SCOPES_FILE = path.join('supabase', 'functions', '_shared', 'api', 'scopes.ts');

const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const isStr = (v) => typeof v === 'string' && v.trim().length > 0;

/**
 * The SCOPES array of _shared/api/scopes.ts, read from its source text (this
 * script runs under plain node, which can't import TypeScript).
 * src/lib/apiReference.test.ts checks it equals the imported SCOPES.
 */
export function readScopes(root = ROOT) {
  const src = fs.readFileSync(path.join(root, SCOPES_FILE), 'utf8');
  const m = /export const SCOPES = \[([\s\S]*?)\]\s*as const/.exec(src);
  if (!m) throw new Error(`${SCOPES_FILE}: could not find "export const SCOPES = [...] as const"`);
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
}

/** Path parameter names in "/a/:id/b/{code}". */
export function pathParams(p) {
  return [...p.matchAll(/:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\}/g)].map((m) => m[1] || m[2]);
}

/** ":id" and "{id}" both become "{}", for comparing shapes. */
export function normalizePath(p) {
  return p.replace(/:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\}/g, '{}').replace(/\/+$/, '') || '/';
}

/**
 * Reads and validates the sources. Never throws for content problems:
 * returns them in `errors` (and non-fatal ones in `warnings`).
 */
export function loadSpec(root = ROOT) {
  const dir = path.join(root, 'docs', 'api');
  const errors = [];
  const warnings = [];
  let meta = null;
  const categories = [];

  let scopes = [];
  try {
    scopes = readScopes(root);
  } catch (err) {
    errors.push(err.message);
  }

  const readJson = (file) => {
    try {
      return JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
    } catch (err) {
      errors.push(`${file}: ${err.message}`);
      return null;
    }
  };

  if (!fs.existsSync(dir)) return { meta, categories, errors: [`${dir} does not exist`], warnings };
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.json')).sort();
  if (!files.includes('_meta.json')) errors.push('docs/api/_meta.json is missing');

  for (const file of files) {
    const data = readJson(file);
    if (data === null) continue;
    if (file === '_meta.json') {
      meta = data;
      validateMeta(meta, errors);
      continue;
    }
    const where = `docs/api/${file}`;
    if (!isObj(data)) {
      errors.push(`${where}: must be an object`);
      continue;
    }
    const stem = file.replace(/\.json$/, '');
    if (data.file !== stem) errors.push(`${where}: "file" must be "${stem}" (got ${JSON.stringify(data.file)})`);
    if (!FILE_RE.test(stem)) errors.push(`${where}: file names are lowercase letters, digits and dashes`);
    if (!isStr(data.name)) errors.push(`${where}: "name" is required`);
    if (typeof data.description !== 'string') errors.push(`${where}: "description" is required (a string)`);
    if (data.group !== undefined && !isStr(data.group)) errors.push(`${where}: "group" must be a non-empty string`);
    if (data.order !== undefined && typeof data.order !== 'number') errors.push(`${where}: "order" must be a number`);
    for (const k of Object.keys(data)) if (!CATEGORY_KEYS.has(k)) warnings.push(`${where}: unknown key "${k}"`);
    if (!Array.isArray(data.endpoints) || data.endpoints.length === 0) {
      errors.push(`${where}: "endpoints" must be a non-empty array`);
      continue;
    }
    data.endpoints.forEach((e, i) => validateEndpoint(e, `${where} endpoints[${i}]${isStr(e?.id) ? ` (${e.id})` : ''}`, scopes, errors, warnings));
    categories.push(data);
  }

  // Cross-file: unique ids, unique method + path.
  const ids = new Map();
  const routes = new Map();
  for (const c of categories) {
    for (const e of c.endpoints) {
      if (!isStr(e?.id)) continue;
      if (ids.has(e.id)) errors.push(`duplicate endpoint id "${e.id}" in ${ids.get(e.id)} and ${c.file}`);
      else ids.set(e.id, c.file);
      if (typeof e.method === 'string' && typeof e.path === 'string') {
        const key = `${e.method} ${normalizePath(e.path)}`;
        if (routes.has(key)) errors.push(`duplicate endpoint ${e.method} ${e.path} ("${routes.get(key)}" and "${e.id}")`);
        else routes.set(key, e.id);
      }
    }
  }
  return { meta, categories, scopes, errors, warnings };
}

function validateMeta(meta, errors) {
  const where = 'docs/api/_meta.json';
  if (!isObj(meta)) {
    errors.push(`${where}: must be an object`);
    return;
  }
  for (const k of ['title', 'version', 'base_url', 'description']) if (!isStr(meta[k])) errors.push(`${where}: "${k}" is required`);
  const auth = meta.authentication;
  if (!isObj(auth)) errors.push(`${where}: "authentication" is required`);
  else {
    for (const k of ['description', 'header', 'format']) if (!isStr(auth[k])) errors.push(`${where}: authentication.${k} is required`);
    if (!Array.isArray(auth.methods) || auth.methods.length === 0) errors.push(`${where}: authentication.methods must be a non-empty array`);
    else {
      for (const m of auth.methods) {
        if (!isObj(m) || !AUTH.includes(m.id)) errors.push(`${where}: authentication.methods[].id must be one of ${AUTH.join(', ')}`);
        else if (!isStr(m.name) || typeof m.description !== 'string') errors.push(`${where}: authentication method "${m.id}" needs name and description`);
      }
      const missing = AUTH.filter((a) => !auth.methods.some((m) => m?.id === a));
      if (missing.length) errors.push(`${where}: authentication.methods is missing ${missing.join(', ')}`);
    }
  }
  if (!isObj(meta.pagination) || !isStr(meta.pagination.description)) errors.push(`${where}: pagination.description is required`);
  if (!isObj(meta.rate_limiting) || !isStr(meta.rate_limiting.description)) errors.push(`${where}: rate_limiting.description is required`);
  if (!Array.isArray(meta.error_codes) || meta.error_codes.some((e) => !isObj(e) || !Number.isInteger(e.status) || !isStr(e.description))) {
    errors.push(`${where}: error_codes must be a list of { status, name, description }`);
  }
  if (meta.webhooks !== undefined && (!isObj(meta.webhooks) || !isStr(meta.webhooks.description) || !isObj(meta.webhooks.signature))) {
    errors.push(`${where}: webhooks needs a description and a signature`);
  }
}

function validateEndpoint(e, where, scopes, errors, warnings) {
  if (!isObj(e)) {
    errors.push(`${where}: must be an object`);
    return;
  }
  if (!isStr(e.id) || !ID_RE.test(e.id)) errors.push(`${where}: "id" must be lowercase letters, digits and dashes (it is the #anchor)`);
  if (!METHODS.includes(e.method)) errors.push(`${where}: "method" must be one of ${METHODS.join(', ')}`);
  if (!isStr(e.path)) errors.push(`${where}: "path" is required`);
  else if (!/^\/v1(\/|$)/.test(e.path)) errors.push(`${where}: "path" must start with /v1 (as the client calls it, relative to base_url)`);
  else if (/[?#\s]/.test(e.path)) errors.push(`${where}: "path" must not contain a query string; use query parameters`);
  if (!isStr(e.summary)) errors.push(`${where}: "summary" is required`);
  if (e.description !== undefined && typeof e.description !== 'string') errors.push(`${where}: "description" must be a string`);
  if (!AUTH.includes(e.auth)) errors.push(`${where}: "auth" must be one of ${AUTH.join(', ')}`);
  if (!('scope' in e)) errors.push(`${where}: "scope" is required (a scope name, or null for any valid key)`);
  else if (e.scope !== null && !scopes.includes(e.scope)) errors.push(`${where}: "scope" ${JSON.stringify(e.scope)} is not in SCOPES (${SCOPES_FILE})`);
  for (const k of Object.keys(e)) if (!ENDPOINT_KEYS.has(k)) warnings.push(`${where}: unknown key "${k}"`);

  if (!Array.isArray(e.parameters)) errors.push(`${where}: "parameters" must be an array (empty when there are none)`);
  else {
    const seen = new Set();
    e.parameters.forEach((p, i) => {
      const w = `${where} parameters[${i}]`;
      if (!isObj(p)) {
        errors.push(`${w}: must be an object`);
        return;
      }
      if (!isStr(p.name)) errors.push(`${w}: "name" is required`);
      if (!LOCATIONS.includes(p.location)) errors.push(`${w}: "location" must be one of ${LOCATIONS.join(', ')}`);
      if (!isStr(p.type)) errors.push(`${w}: "type" is required`);
      if (typeof p.required !== 'boolean') errors.push(`${w}: "required" must be true or false`);
      if (typeof p.description !== 'string') errors.push(`${w}: "description" is required (a string)`);
      if (p.enum !== undefined && !Array.isArray(p.enum)) errors.push(`${w}: "enum" must be an array`);
      for (const k of Object.keys(p)) if (!PARAM_KEYS.has(k)) warnings.push(`${w}: unknown key "${k}"`);
      const key = `${p.location}:${p.name}`;
      if (seen.has(key)) errors.push(`${w}: duplicate parameter ${p.name} in ${p.location}`);
      seen.add(key);
      if (p.location === 'path' && p.required !== true) errors.push(`${w}: path parameters are always required`);
    });
    if (isStr(e.path)) {
      const inPath = pathParams(e.path);
      const declared = e.parameters.filter((p) => isObj(p) && p.location === 'path').map((p) => p.name);
      for (const n of inPath) if (!declared.includes(n)) errors.push(`${where}: path parameter "${n}" is not in "parameters"`);
      for (const n of declared) if (!inPath.includes(n)) errors.push(`${where}: parameter "${n}" (location path) is not in the path`);
    }
  }

  if (!Array.isArray(e.responses) || e.responses.length === 0) errors.push(`${where}: "responses" must be a non-empty array`);
  else {
    e.responses.forEach((r, i) => {
      const w = `${where} responses[${i}]`;
      if (!isObj(r)) {
        errors.push(`${w}: must be an object`);
        return;
      }
      if (!Number.isInteger(r.status) || r.status < 100 || r.status > 599) errors.push(`${w}: "status" must be an HTTP status code`);
      if (typeof r.description !== 'string') errors.push(`${w}: "description" is required (a string)`);
      if (r.headers !== undefined && !isObj(r.headers)) errors.push(`${w}: "headers" must be an object of name -> description`);
      for (const k of Object.keys(r)) if (!RESPONSE_KEYS.has(k)) warnings.push(`${w}: unknown key "${k}"`);
    });
    if (!e.responses.some((r) => isObj(r) && r.status >= 200 && r.status < 300 && r.example !== undefined)) {
      errors.push(`${where}: needs a 2xx response with an example`);
    }
  }
}

/** Sidebar order: groups by their first category's order, categories by order then name. */
export function bundleSpec({ meta, categories }) {
  const cats = categories
    .map((c) => ({
      file: c.file,
      name: c.name,
      description: c.description,
      group: c.group || DEFAULT_GROUP,
      order: typeof c.order === 'number' ? c.order : DEFAULT_ORDER,
      endpoints: c.endpoints,
    }))
    .sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));
  const groupOrder = [];
  for (const c of cats) if (!groupOrder.includes(c.group)) groupOrder.push(c.group);
  cats.sort((a, b) => groupOrder.indexOf(a.group) - groupOrder.indexOf(b.group) || a.order - b.order || a.name.localeCompare(b.name));
  return { ...meta, groups: groupOrder, categories: cats };
}

// -- OpenAPI 3.1 --------------------------------------------------------------

/** "string (ISO 8601) or null" → a JSON schema. */
export function typeSchema(type, enumValues) {
  const parts = String(type).toLowerCase().split(/\s+or\s+/).map((s) => s.trim());
  const nullable = parts.includes('null');
  const base = parts.find((s) => s !== 'null') || 'string';
  let schema;
  if (base.startsWith('integer')) schema = { type: 'integer' };
  else if (base.startsWith('number')) schema = { type: 'number' };
  else if (base.startsWith('boolean')) schema = { type: 'boolean' };
  else if (base.startsWith('array')) schema = { type: 'array', items: base.includes('string') ? { type: 'string' } : base.includes('object') ? { type: 'object' } : {} };
  else if (base.startsWith('object')) schema = { type: 'object' };
  else {
    schema = { type: 'string' };
    if (base.includes('iso 8601')) schema.format = 'date-time';
    else if (base.includes('uuid')) schema.format = 'uuid';
    else if (base.includes('url')) schema.format = 'uri';
  }
  if (Array.isArray(enumValues)) schema.enum = enumValues;
  if (nullable) schema.type = [schema.type, 'null'];
  return schema;
}

const SECURITY = {
  api_key: { type: 'http', scheme: 'bearer', bearerFormat: 'sk_live_…', description: 'Organization API key, created in Org settings → Developer.' },
};

function operation(e, category) {
  const scopeLine = e.scope ? `Requires the \`${e.scope}\` scope.` : 'Any valid API key.';
  const op = {
    operationId: e.id,
    summary: e.summary,
    description: e.description ? `${e.description}\n\n${scopeLine}` : scopeLine,
    tags: [category.name],
    security: SECURITY[e.auth] ? [{ [e.auth]: [] }] : [],
    'x-required-scope': e.scope,
  };
  if (e.deprecated) op.deprecated = true;
  const params = e.parameters
    .filter((p) => p.location !== 'body' && !/^\(.*\)$/.test(p.name))
    .map((p) => ({
      name: p.name,
      in: p.location,
      required: p.location === 'path' ? true : p.required,
      description: p.description,
      schema: { ...typeSchema(p.type, p.enum), ...(p.default !== undefined ? { default: p.default } : {}) },
      ...(p.example !== undefined ? { example: p.example } : {}),
    }));
  if (params.length) op.parameters = params;
  const body = e.parameters.filter((p) => p.location === 'body');
  if (body.length || e.request_example !== undefined) {
    const schema = {
      type: 'object',
      properties: Object.fromEntries(body.map((p) => [p.name, { ...typeSchema(p.type, p.enum), description: p.description }])),
      ...(body.some((p) => p.required) ? { required: body.filter((p) => p.required).map((p) => p.name) } : {}),
    };
    op.requestBody = {
      required: body.some((p) => p.required),
      content: { 'application/json': { schema, ...(e.request_example !== undefined ? { example: e.request_example } : {}) } },
    };
  }
  const byStatus = new Map();
  for (const r of e.responses) {
    const key = String(r.status);
    if (!byStatus.has(key)) byStatus.set(key, []);
    byStatus.get(key).push(r);
  }
  op.responses = {};
  for (const [status, list] of byStatus) {
    const resp = { description: list.map((r) => r.description).filter(Boolean).join(' / ') || status };
    const withExample = list.filter((r) => r.example !== undefined);
    if (withExample.length) {
      const type = withExample[0].content_type || 'application/json';
      resp.content = {
        [type]: withExample.length === 1
          ? { example: withExample[0].example }
          : { examples: Object.fromEntries(withExample.map((r, i) => [`example${i + 1}`, { summary: r.description, value: r.example }])) },
      };
    }
    const headers = Object.assign({}, ...list.map((r) => r.headers || {}));
    if (Object.keys(headers).length) {
      resp.headers = Object.fromEntries(Object.entries(headers).map(([n, d]) => [n, { description: String(d), schema: { type: 'string' } }]));
    }
    op.responses[status] = resp;
  }
  return op;
}

export function toOpenApi(bundle) {
  const doc = {
    openapi: '3.1.0',
    info: { title: bundle.title, version: bundle.version, description: bundle.description },
    servers: [{ url: bundle.base_url, description: 'The exos-api edge function of your Supabase project' }],
    tags: bundle.categories.map((c) => ({ name: c.name, description: c.description })),
    paths: {},
    components: { securitySchemes: SECURITY },
  };
  for (const c of bundle.categories) {
    for (const e of c.endpoints) {
      const p = e.path.replace(/:([A-Za-z_][A-Za-z0-9_]*)/g, '{$1}');
      doc.paths[p] = doc.paths[p] || {};
      doc.paths[p][e.method.toLowerCase()] = operation(e, c);
    }
  }
  return doc;
}

// -- Output ---------------------------------------------------------------------

function writeIfChanged(file, text) {
  if (fs.existsSync(file) && fs.readFileSync(file, 'utf8') === text) return false;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  return true;
}

/** Validates and writes api-spec.json + openapi.json into outDir. Throws on validation errors. */
export function buildSpecFiles({ root = ROOT, outDir = path.join(root, 'public') } = {}) {
  const spec = loadSpec(root);
  if (spec.errors.length) {
    const err = new Error(`API spec has ${spec.errors.length} error(s):\n  ${spec.errors.join('\n  ')}`);
    err.specErrors = spec.errors;
    throw err;
  }
  const bundle = bundleSpec(spec);
  const openapi = toOpenApi(bundle);
  writeIfChanged(path.join(outDir, 'api-spec.json'), JSON.stringify(bundle) + '\n');
  writeIfChanged(path.join(outDir, 'openapi.json'), JSON.stringify(openapi, null, 2) + '\n');
  const endpoints = bundle.categories.reduce((n, c) => n + c.endpoints.length, 0);
  return { bundle, openapi, warnings: spec.warnings, categories: bundle.categories.length, endpoints };
}

// -- CLI ---------------------------------------------------------------------------

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const check = args.includes('--check');
  const outIdx = args.indexOf('--out');
  const outDir = outIdx >= 0 ? path.resolve(args[outIdx + 1] || '') : path.join(ROOT, 'public');
  const spec = loadSpec(ROOT);
  for (const w of spec.warnings) console.warn(`api-spec: warning: ${w}`);
  if (spec.errors.length) {
    for (const e of spec.errors) console.error(`api-spec: ${e}`);
    console.error(`api-spec: ${spec.errors.length} error(s)`);
    process.exit(1);
  }
  const endpoints = spec.categories.reduce((n, c) => n + c.endpoints.length, 0);
  if (check) {
    console.log(`api-spec: ok (${spec.categories.length} categories, ${endpoints} endpoints)`);
  } else {
    const r = buildSpecFiles({ root: ROOT, outDir });
    console.log(`api-spec: wrote ${path.relative(ROOT, path.join(outDir, 'api-spec.json'))} and openapi.json (${r.categories} categories, ${r.endpoints} endpoints)`);
  }
}
