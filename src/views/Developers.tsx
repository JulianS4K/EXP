import { Fragment, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { Check, ChevronRight, Code2, Copy, Download, Search } from 'lucide-react';
import { cn } from '../lib/utils';
import { applyMeta } from '../lib/meta';
import { LEGACY_READ, SCOPES, SCOPE_INFO } from '../../supabase/functions/_shared/api/scopes.ts';

// ---------------------------------------------------------------------------
// Partner API reference at /developers, rendered from api-spec.json.
// docs/api-reference.md.
//
// The spec is docs/api/_meta.json plus one docs/api/<category>.json per area,
// validated and bundled by scripts/api-spec.mjs at build time (the Vite
// plugin in vite.config.ts) into public/api-spec.json, with openapi.json
// beside it. This page only renders it: a sidebar of getting-started
// sections and endpoints (a <select> on phones) with a search box, then one
// anchored block per endpoint (#<id>) with method, path, scope, parameters, a
// curl example and collapsible response examples. The scope table comes from
// SCOPE_INFO (_shared/api/scopes.ts), the same list the key UI offers.
//
// Public page: no auth, no Supabase client. Ported from the Firebase build's
// src/views/Developers.tsx (Exos-Bridge PR #1).
// ---------------------------------------------------------------------------

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

interface SpecParam {
  name: string;
  location: 'path' | 'query' | 'body' | 'header';
  type: string;
  required: boolean;
  description: string;
  example?: unknown;
  enum?: unknown[];
  default?: unknown;
}

interface SpecResponse {
  status: number;
  description: string;
  example?: unknown;
  headers?: Record<string, string>;
}

interface SpecEndpoint {
  id: string;
  method: Method;
  path: string;
  summary: string;
  description?: string;
  auth: 'api_key';
  scope: string | null;
  parameters: SpecParam[];
  responses: SpecResponse[];
}

interface SpecCategory {
  file: string;
  name: string;
  description: string;
  group: string;
  order: number;
  endpoints: SpecEndpoint[];
}

interface Spec {
  title: string;
  version: string;
  base_url: string;
  description: string;
  authentication: {
    description: string;
    header: string;
    format: string;
    token_validity?: string;
    scopes_description?: string;
  };
  pagination: { description: string; parameters?: SpecParam[]; response_format?: unknown };
  rate_limiting: { description: string };
  error_format?: { description: string; example?: unknown; unknown_path_example?: unknown };
  error_codes: { status: number; name?: string; description: string }[];
  webhooks?: {
    description: string;
    signature: { header: string; format: string; description?: string };
    headers?: { name: string; description: string }[];
    retries?: string;
  };
  groups: string[];
  categories: SpecCategory[];
}

const GUIDES = [
  { id: 'guide-overview', label: 'Overview' },
  { id: 'guide-authentication', label: 'Authentication' },
  { id: 'guide-scopes', label: 'Scopes' },
  { id: 'guide-pagination', label: 'Pagination' },
  { id: 'guide-errors', label: 'Errors' },
  { id: 'guide-rate-limits', label: 'Rate limits' },
  { id: 'guide-webhooks', label: 'Webhooks' },
] as const;

const BASE = ((import.meta as any).env?.BASE_URL ?? '/') as string;

/** The live exos-api URL when this build knows its Supabase project, else the spec's placeholder. */
function apiBase(spec: Spec): string {
  const sb = ((import.meta as any).env?.VITE_SUPABASE_URL as string | undefined)?.replace(/\/+$/, '');
  return sb ? `${sb}/functions/v1/exos-api` : spec.base_url;
}

function pretty(value: unknown): string {
  return typeof value === 'string' ? value : JSON.stringify(value, null, 2);
}

/** Path with :params replaced by their examples. */
function samplePath(e: SpecEndpoint): string {
  return e.path.replace(/:([A-Za-z_]\w*)/g, (_m, name: string) => {
    const p = e.parameters.find((x) => x.location === 'path' && x.name === name);
    return p && p.example !== undefined ? encodeURIComponent(String(p.example)) : `<${name}>`;
  });
}

function curlFor(e: SpecEndpoint, base: string): string {
  const query = e.parameters
    .filter((p) => p.location === 'query' && p.example !== undefined && p.name !== 'page')
    .slice(0, 2)
    .map((p) => `${encodeURIComponent(p.name)}=${encodeURIComponent(String(p.example))}`)
    .join('&');
  return [
    `curl${e.method === 'GET' ? '' : ` -X ${e.method}`} "${base}${samplePath(e)}${query ? `?${query}` : ''}"`,
    '  -H "Authorization: Bearer $EXOS_API_KEY"',
  ].join(' \\\n');
}

function matches(e: SpecEndpoint, q: string): boolean {
  if (!q) return true;
  return `${e.method} ${e.path} ${e.summary} ${e.id} ${e.scope ?? ''}`.toLowerCase().includes(q);
}

function CopyButton({ text, label }: { text: string; label: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={() => {
        navigator.clipboard?.writeText(text).then(() => {
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1500);
        }).catch(() => {});
      }}
      className="inline-flex items-center gap-1.5 min-h-8 px-2.5 text-[10px] font-black uppercase tracking-widest text-white/70 hover:text-white border border-white/15 hover:border-brand-primary transition-colors shrink-0 bg-black"
    >
      {copied ? <Check className="w-3.5 h-3.5 text-brand-primary" aria-hidden="true" /> : <Copy className="w-3.5 h-3.5" aria-hidden="true" />}
      {copied ? 'Copied' : 'Copy'}
    </button>
  );
}

function Code({ children }: { children: ReactNode }) {
  return <code className="font-mono text-[12px] text-white/90 bg-white/5 border border-white/10 px-1.5 py-0.5 break-words">{children}</code>;
}

function Pre({ children, label }: { children: string; label?: string }) {
  return (
    <div className="relative">
      <pre className="text-[12px] leading-relaxed font-mono text-white/80 bg-[#0a0a0a] border border-white/10 p-4 overflow-x-auto max-h-[28rem]">
        <code>{children}</code>
      </pre>
      {label ? <div className="absolute top-2 right-2"><CopyButton text={children} label={label} /></div> : null}
    </div>
  );
}

function Pill({ tone, children }: { tone: 'green' | 'amber' | 'red' | 'blue' | 'neutral'; children: ReactNode }) {
  const cls = {
    green: 'border-green-400/40 text-green-300',
    amber: 'border-amber-400/40 text-amber-300',
    red: 'border-red-400/40 text-red-300',
    blue: 'border-sky-400/40 text-sky-300',
    neutral: 'border-white/20 text-white/70',
  }[tone];
  return <span className={cn('inline-flex items-center px-2 py-0.5 border text-[10px] font-black uppercase tracking-widest', cls)}>{children}</span>;
}

function statusTone(status: number) {
  return status < 300 ? 'green' : status < 500 ? 'amber' : 'red';
}

function SectionHeading({ id, children }: { id?: string; children: ReactNode }) {
  return <h2 id={id} className="text-xl md:text-2xl font-black uppercase italic tracking-tighter text-white mb-3 scroll-mt-24">{children}</h2>;
}

function SubHeading({ children }: { children: ReactNode }) {
  return <h4 className="text-[11px] font-black uppercase tracking-widest text-white/60 mt-6 mb-2">{children}</h4>;
}

function Table({ head, children, testId }: { head: string[]; children: ReactNode; testId?: string }) {
  return (
    <div className="overflow-x-auto border border-white/10">
      <table className="w-full text-left text-sm min-w-[32rem]" data-testid={testId}>
        <thead className="bg-white/[0.03] text-[11px] font-black uppercase tracking-widest text-white/60">
          <tr>{head.map((h) => <th key={h} scope="col" className="px-3 py-2">{h}</th>)}</tr>
        </thead>
        <tbody className="divide-y divide-white/10">{children}</tbody>
      </table>
    </div>
  );
}

function ParamTable({ params }: { params: SpecParam[] }) {
  return (
    <Table head={['Name', 'In', 'Type', 'Description']}>
      {params.map((p) => (
        <tr key={`${p.location}:${p.name}`} className="align-top">
          <td className="px-3 py-2">
            <span className="font-mono text-[12px] text-white whitespace-nowrap">{p.name}</span>
            {p.required ? <span className="block text-[10px] font-black uppercase tracking-widest text-amber-300 mt-1">Required</span> : null}
          </td>
          <td className="px-3 py-2 text-white/70">{p.location}</td>
          <td className="px-3 py-2 text-white/70 whitespace-nowrap">{p.type}</td>
          <td className="px-3 py-2 text-white/70 leading-relaxed">
            {p.description}
            {p.enum?.length ? <span className="block mt-1 text-white/50">One of: {p.enum.map(String).join(', ')}</span> : null}
            {p.example !== undefined ? (
              <span className="block mt-1 text-white/50 break-all">Example: <span className="font-mono text-[12px] text-white/80">{String(p.example)}</span></span>
            ) : null}
          </td>
        </tr>
      ))}
    </Table>
  );
}

function ScopeBadge({ scope }: { scope: string | null }) {
  return scope
    ? <span className="text-xs text-white/60">Scope <Code>{scope}</Code></span>
    : <span className="text-xs text-white/60">Any valid key (no scope needed)</span>;
}

function EndpointBlock({ e, base }: { e: SpecEndpoint; base: string }) {
  const firstOk = e.responses.findIndex((r) => r.status < 300);
  return (
    <article id={e.id} aria-labelledby={`${e.id}-title`} className="scroll-mt-24 border-t border-white/10 pt-8 mt-8">
      <h3 id={`${e.id}-title`} className="text-lg font-black text-white mb-3">
        <a href={`#${e.id}`} className="hover:text-brand-primary">{e.summary}</a>
      </h3>
      <div className="flex flex-wrap items-center gap-2 mb-3">
        <Pill tone={e.method === 'GET' ? 'green' : 'blue'}>{e.method}</Pill>
        <code className="font-mono text-[13px] text-white break-all">{e.path}</code>
      </div>
      <div className="mb-4"><ScopeBadge scope={e.scope} /></div>
      {e.description ? <p className="text-sm text-white/70 leading-relaxed max-w-3xl">{e.description}</p> : null}

      {e.parameters.length ? (<><SubHeading>Parameters</SubHeading><ParamTable params={e.parameters} /></>) : null}

      <SubHeading>Example request</SubHeading>
      <Pre label={`Copy curl for ${e.method} ${e.path}`}>{curlFor(e, base)}</Pre>

      <SubHeading>Responses</SubHeading>
      <div className="space-y-2">
        {e.responses.map((r, i) => (
          <details key={i} open={i === firstOk} className="group border border-white/10 bg-white/[0.02]">
            <summary className="flex flex-wrap items-center gap-3 px-3 py-2 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
              <ChevronRight className="w-4 h-4 text-white/60 transition-transform group-open:rotate-90" aria-hidden="true" />
              <Pill tone={statusTone(r.status)}>{r.status}</Pill>
              <span className="text-sm text-white/70 flex-1 min-w-0">{r.description}</span>
            </summary>
            {r.example !== undefined || r.headers ? (
              <div className="px-3 pb-3 space-y-2">
                {r.headers ? Object.entries(r.headers).map(([h, d]) => (
                  <p key={h} className="text-xs text-white/60">Header <span className="font-mono text-white/80">{h}</span>: {d}</p>
                )) : null}
                {r.example !== undefined ? <Pre>{pretty(r.example)}</Pre> : null}
              </div>
            ) : null}
          </details>
        ))}
      </div>
    </article>
  );
}

function Guides({ spec, base }: { spec: Spec; base: string }) {
  const auth = spec.authentication;
  const wh = spec.webhooks;
  const me = `curl "${base}/v1/me" \\\n  -H "Authorization: Bearer $EXOS_API_KEY"`;
  return (
    <>
      <section aria-labelledby="guide-overview" className="mb-14">
        <SectionHeading id="guide-overview">Overview</SectionHeading>
        <p className="text-sm text-white/70 leading-relaxed max-w-3xl">{spec.description}</p>
        <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
          <dt className="text-white/60">Base URL</dt>
          <dd className="min-w-0"><Code>{base}</Code></dd>
          <dt className="text-white/60">Version</dt>
          <dd className="text-white/80">{spec.version} (paths start with <Code>/v1</Code>)</dd>
          <dt className="text-white/60">Formats</dt>
          <dd className="text-white/80">JSON out, times in ISO 8601 (UTC)</dd>
        </dl>
        <div className="mt-5 flex flex-wrap gap-3">
          <a href={`${BASE}openapi.json`} download="exos-openapi.json" className="inline-flex items-center gap-2 min-h-11 px-5 py-3 text-xs font-black uppercase tracking-widest bg-white/5 border border-white/20 text-white hover:border-brand-primary hover:text-brand-primary">
            <Download className="w-4 h-4" aria-hidden="true" /> Download openapi.json
          </a>
        </div>
        <p className="text-xs text-white/50 mt-3">OpenAPI 3.1, for Postman, Insomnia or a client generator.</p>
        <SubHeading>First call</SubHeading>
        <Pre label="Copy the first call">{me}</Pre>
      </section>

      <section aria-labelledby="guide-authentication" className="mb-14">
        <SectionHeading id="guide-authentication">Authentication</SectionHeading>
        <p className="text-sm text-white/70 leading-relaxed max-w-3xl">{auth.description}</p>
        <p className="text-sm text-white/70 mt-3"><Code>{`${auth.header}: ${auth.format}`}</Code></p>
        <p className="text-sm text-white/70 leading-relaxed max-w-3xl mt-3">
          Create a key under <Link to="/orgs" className="underline text-white">your organization's settings</Link> → Developer.
          {auth.token_validity ? ` ${auth.token_validity}` : ''}
        </p>
      </section>

      <section aria-labelledby="guide-scopes" className="mb-14">
        <SectionHeading id="guide-scopes">Scopes</SectionHeading>
        {auth.scopes_description ? <p className="text-sm text-white/70 leading-relaxed max-w-3xl mb-4">{auth.scopes_description}</p> : null}
        <Table head={['Scope', 'Allows']} testId="scopes-table">
          {[LEGACY_READ, ...SCOPES].map((s) => (
            <tr key={s} className="align-top">
              <td className="px-3 py-2 font-mono text-[12px] text-white whitespace-nowrap">{s}</td>
              <td className="px-3 py-2 text-white/70">
                {s === LEGACY_READ
                  ? <><span className="text-white font-bold">All read access (legacy).</span> Keys made before scopes existed; covers every <Code>:read</Code> scope.</>
                  : <><span className="text-white font-bold">{SCOPE_INFO[s as keyof typeof SCOPE_INFO].label}.</span> {SCOPE_INFO[s as keyof typeof SCOPE_INFO].description}</>}
              </td>
            </tr>
          ))}
        </Table>
      </section>

      <section aria-labelledby="guide-pagination" className="mb-14">
        <SectionHeading id="guide-pagination">Pagination</SectionHeading>
        <p className="text-sm text-white/70 leading-relaxed max-w-3xl">{spec.pagination.description}</p>
        {spec.pagination.parameters?.length ? <div className="mt-4"><ParamTable params={spec.pagination.parameters} /></div> : null}
        {spec.pagination.response_format !== undefined ? (<><SubHeading>Paged response</SubHeading><Pre>{pretty(spec.pagination.response_format)}</Pre></>) : null}
      </section>

      <section aria-labelledby="guide-errors" className="mb-14">
        <SectionHeading id="guide-errors">Errors</SectionHeading>
        {spec.error_format ? <p className="text-sm text-white/70 leading-relaxed max-w-3xl">{spec.error_format.description}</p> : null}
        {spec.error_format?.example !== undefined ? <div className="mt-3"><Pre>{pretty(spec.error_format.example)}</Pre></div> : null}
        <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
          {spec.error_codes.map((c) => (
            <div key={c.status} className="contents">
              <dt className="font-mono text-white/90">{c.status}</dt>
              <dd className="text-white/70">{c.name ? <span className="text-white font-bold">{c.name}. </span> : null}{c.description}</dd>
            </div>
          ))}
        </dl>
      </section>

      <section aria-labelledby="guide-rate-limits" className="mb-14">
        <SectionHeading id="guide-rate-limits">Rate limits</SectionHeading>
        <p className="text-sm text-white/70 leading-relaxed max-w-3xl">{spec.rate_limiting.description}</p>
      </section>

      {wh ? (
        <section aria-labelledby="guide-webhooks" className="mb-14">
          <SectionHeading id="guide-webhooks">Webhooks</SectionHeading>
          <p className="text-sm text-white/70 leading-relaxed max-w-3xl">{wh.description}</p>
          <p className="text-sm text-white/70 mt-3"><Code>{`${wh.signature.header}: ${wh.signature.format}`}</Code></p>
          {wh.signature.description ? <p className="text-sm text-white/70 leading-relaxed max-w-3xl mt-2">{wh.signature.description}</p> : null}
          {wh.headers?.length ? (
            <ul className="mt-3 space-y-1 text-sm text-white/70">
              {wh.headers.map((h) => <li key={h.name}><span className="font-mono text-[12px] text-white">{h.name}</span> — {h.description}</li>)}
            </ul>
          ) : null}
          {wh.retries ? <p className="text-sm text-white/70 leading-relaxed max-w-3xl mt-3">{wh.retries}</p> : null}
        </section>
      ) : null}
    </>
  );
}

function Sidebar({ query, setQuery, filtered, active }: {
  query: string;
  setQuery: (q: string) => void;
  filtered: SpecCategory[];
  active: string;
}) {
  const total = filtered.reduce((n, c) => n + c.endpoints.length, 0);
  const inputCls = 'w-full bg-white/5 border border-white/10 px-3 py-2 text-sm text-white focus:border-brand-primary focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
  return (
    <>
      <div className="relative">
        <Search className="w-4 h-4 text-white/50 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" aria-hidden="true" />
        <input type="search" value={query} onChange={(ev) => setQuery(ev.target.value)} placeholder="Search endpoints" aria-label="Search endpoints" className={cn(inputCls, 'pl-9')} />
      </div>
      <p className="text-xs text-white/50 mt-2" aria-live="polite">
        {query ? `${total} endpoint${total === 1 ? '' : 's'} match` : `${total} endpoints`}
      </p>

      {/* Phones: one select to jump anywhere. */}
      <label className="lg:hidden block mt-3">
        <span className="sr-only">Jump to section</span>
        <select className={inputCls} value="" onChange={(ev) => { if (ev.target.value) window.location.hash = ev.target.value; }}>
          <option value="">Jump to…</option>
          <optgroup label="Getting started">
            {GUIDES.map((g) => <option key={g.id} value={g.id}>{g.label}</option>)}
          </optgroup>
          {filtered.map((c) => (
            <optgroup key={c.file} label={c.name}>
              {c.endpoints.map((e) => <option key={e.id} value={e.id}>{e.method} · {e.summary}</option>)}
            </optgroup>
          ))}
        </select>
      </label>

      <nav aria-label="API reference" className="hidden lg:block mt-5 space-y-6">
        <div>
          <p className="text-[11px] font-black uppercase tracking-widest text-white/50 mb-2">Getting started</p>
          <ul className="space-y-0.5">
            {GUIDES.map((g) => (
              <li key={g.id}>
                <a href={`#${g.id}`} aria-current={active === g.id ? 'location' : undefined} className={cn('block px-2 py-1 text-sm hover:text-white', active === g.id ? 'text-brand-primary' : 'text-white/70')}>{g.label}</a>
              </li>
            ))}
          </ul>
        </div>
        <ul className="space-y-3">
          {filtered.map((c) => (
            <li key={c.file}>
              <a href={`#cat-${c.file}`} className="block px-2 py-1 text-sm font-bold text-white hover:text-brand-primary">{c.name}</a>
              <ul className="border-l border-white/10 ml-2">
                {c.endpoints.map((e) => (
                  <li key={e.id}>
                    <a href={`#${e.id}`} aria-current={active === e.id ? 'location' : undefined} className={cn('flex items-baseline gap-2 pl-3 pr-2 py-1 text-[13px] hover:text-white', active === e.id ? 'text-brand-primary' : 'text-white/70')}>
                      <span className="w-9 shrink-0 text-[10px] font-black tracking-widest text-green-300">{e.method}</span>
                      <span className="min-w-0">{e.summary}</span>
                    </a>
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ul>
        {query && total === 0 ? <p className="text-sm text-white/50">No endpoint matches “{query}”.</p> : null}
      </nav>
    </>
  );
}

export default function Developers() {
  const [spec, setSpec] = useState<Spec | null>(null);
  const [error, setError] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [query, setQuery] = useState('');
  const [active, setActive] = useState('');
  const scrolledFor = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setError(false);
    fetch(`${BASE}api-spec.json`, { headers: { Accept: 'application/json' } })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((data: Spec) => { if (!cancelled) setSpec(data); })
      .catch(() => { if (!cancelled) setError(true); });
    return () => { cancelled = true; };
  }, [attempt]);

  useEffect(() => {
    try {
      applyMeta({ title: 'Developers', description: 'The Exos API: endpoints, scopes, examples and the OpenAPI file.' });
    } catch { /* non-fatal */ }
  }, []);

  // Deep links: scroll to #<id> once the spec has rendered, and on every hash change.
  const scrollToHash = useCallback((smooth: boolean) => {
    const id = decodeURIComponent(window.location.hash.slice(1));
    if (!id) return;
    const el = document.getElementById(id);
    if (!el) return;
    el.scrollIntoView({ behavior: smooth ? 'smooth' : 'auto', block: 'start' });
    setActive(id);
  }, []);

  useEffect(() => {
    if (!spec) return undefined;
    if (scrolledFor.current !== window.location.hash) {
      scrolledFor.current = window.location.hash;
      requestAnimationFrame(() => scrollToHash(false));
    }
    const onHash = () => scrollToHash(true);
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, [spec, scrollToHash]);

  const q = query.trim().toLowerCase();
  const filtered = useMemo(() => {
    if (!spec) return [];
    return spec.categories
      .map((c) => ({ ...c, endpoints: c.endpoints.filter((e) => matches(e, q) || (q && c.name.toLowerCase().includes(q))) }))
      .filter((c) => c.endpoints.length > 0);
  }, [spec, q]);

  const base = spec ? apiBase(spec) : '';

  return (
    <div className="max-w-7xl mx-auto px-4 py-12 md:py-16 text-white">
      <header className="mb-10 max-w-3xl">
        <div className="flex items-center gap-4 mb-4">
          <div className="w-12 h-12 border border-brand-primary/40 bg-brand-primary/10 flex items-center justify-center shrink-0">
            <Code2 className="w-6 h-6 text-brand-primary" aria-hidden="true" />
          </div>
          <h1 className="text-3xl md:text-4xl font-black uppercase italic tracking-tighter">Developers</h1>
        </div>
        <p className="text-white/70 leading-relaxed">
          The Exos API: read your organization's events, attendees, door scans, orders and refunds from
          your own systems, with an API key scoped to just what the integration needs.
        </p>
      </header>

      {error ? (
        <div role="alert" className="border border-red-400/40 bg-red-500/10 p-4 flex flex-wrap items-center gap-4">
          <p className="text-sm text-red-200 flex-1">The API reference could not be loaded.</p>
          <button type="button" onClick={() => setAttempt((n) => n + 1)} className="px-3 py-2 bg-white/10 hover:bg-white/20 text-[10px] font-black uppercase tracking-widest text-white">
            Try again
          </button>
        </div>
      ) : !spec ? (
        <p className="text-sm text-white/50" role="status">Loading the API reference…</p>
      ) : (
        <div className="lg:grid lg:grid-cols-[17rem_minmax(0,1fr)] lg:gap-10">
          <aside className="mb-10 lg:mb-0">
            <div className="lg:sticky lg:top-24 lg:max-h-[calc(100vh-7rem)] lg:overflow-y-auto lg:pr-2">
              <Sidebar query={query} setQuery={setQuery} filtered={filtered} active={active} />
            </div>
          </aside>
          <div className="min-w-0">
            <Guides spec={spec} base={base} />
            {spec.categories.map((c) => (
              <section key={c.file} id={`cat-${c.file}`} aria-labelledby={`cat-${c.file}-title`} className="mb-16 scroll-mt-24">
                <p className="text-[11px] font-black uppercase tracking-widest text-brand-primary mb-2">{c.group}</p>
                <SectionHeading id={`cat-${c.file}-title`}>{c.name}</SectionHeading>
                <p className="text-sm text-white/70 leading-relaxed max-w-3xl">{c.description}</p>
                {c.endpoints.map((e) => <Fragment key={e.id}><EndpointBlock e={e} base={base} /></Fragment>)}
              </section>
            ))}
            <p className="text-xs text-white/50 border border-white/10 p-3">
              Generated from <Code>docs/api/*.json</Code> in the repository; see <Code>docs/api-reference.md</Code>.
            </p>
          </div>
        </div>
      )}
    </div>
  );
}
