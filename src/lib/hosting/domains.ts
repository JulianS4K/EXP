// Custom domains (mig 20261016130000): tickets.venue.com serves the same app;
// its root goes to the org's storefront. Pure parts here; server.ts wires it.

/** Lower-case host without port; null when unusable. */
export function hostOnly(raw: string | undefined | null): string | null {
  if (!raw) return null;
  const h = raw.trim().toLowerCase().replace(/:\d+$/, '').replace(/\.$/, '');
  return /^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(h) || h === 'localhost' ? h : null;
}

/** Hosts that are Exos itself (never treated as an org's domain). */
export function primaryHosts(publicBase: string | undefined, extra: string[] = []): Set<string> {
  const out = new Set<string>(['localhost', ...extra.map((h) => h.toLowerCase())]);
  try {
    if (publicBase) out.add(new URL(publicBase).hostname.toLowerCase());
  } catch { /* unset or bad: only localhost */ }
  return out;
}

export function isPrimary(host: string, primaries: Set<string>): boolean {
  return primaries.has(host) || host.endsWith('.onrender.com');
}

/** Where a request on an org's domain should go, or null (serve it as is).
 *  Only the bare root moves: every other path is the normal app. */
export function domainRedirect(path: string, slug: string | null): string | null {
  if (!slug || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$/.test(slug)) return null;
  if (path === '/' || path === '' || path === '/bridge' || path === '/bridge/') return `/bridge/o/${slug}`;
  return null;
}

/** A small TTL cache for domain -> slug lookups (misses cached too). */
export function ttlCache<V>(ttlMs: number, max = 500) {
  const m = new Map<string, { v: V; at: number }>();
  return {
    get(k: string, now = Date.now()): V | undefined {
      const e = m.get(k);
      if (!e) return undefined;
      if (now - e.at > ttlMs) { m.delete(k); return undefined; }
      return e.v;
    },
    set(k: string, v: V, now = Date.now()) {
      if (m.size >= max) m.delete(m.keys().next().value as string);
      m.set(k, { v, at: now });
    },
  };
}
