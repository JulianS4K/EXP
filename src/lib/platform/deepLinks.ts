// Universal Links (iOS) / App Links (Android) into the native app, and the
// way back from the browser sheet. A link the OS hands the app is an https
// URL on the public web app; the app opens the matching route of its bundled
// copy. Only the routes the app's association files claim are followed
// (apps/native/deep-links/), and only on the app's own web host: anything
// else is ignored, never navigated to.

/** Route prefixes the app claims (apps/native/deep-links/*, AndroidManifest.xml). */
export const APP_LINK_ROUTES = ['/door', '/checkin/', '/my-tickets'] as const;

function routeAllowed(path: string): boolean {
  return APP_LINK_ROUTES.some((r) => (r.endsWith('/') ? path.startsWith(r) : path === r || path.startsWith(`${r}/`) || path.startsWith(`${r}?`)));
}

/**
 * The app route (with query) for an incoming link, or null to ignore it.
 * `webBase` is the public web app (https://host/bridge, lib/platform/native
 * nativeWebBase); `extraHosts` are other hosts the association files cover
 * (a custom domain serving the app at its root).
 */
export function appRouteForUrl(url: string, webBase: string | null, extraHosts: readonly string[] = []): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' || u.username || u.password) return null;
  const bases: { host: string; path: string }[] = [];
  if (webBase) {
    try {
      const b = new URL(webBase);
      bases.push({ host: b.host, path: b.pathname.replace(/\/+$/, '') });
      // The same host may also serve the app at its root (after the DNS split).
      if (b.pathname.replace(/\/+$/, '')) bases.push({ host: b.host, path: '' });
    } catch {
      /* no web base */
    }
  }
  for (const h of extraHosts) {
    bases.push({ host: h.toLowerCase(), path: '' }, { host: h.toLowerCase(), path: '/bridge' });
  }
  for (const b of bases) {
    if (u.host.toLowerCase() !== b.host.toLowerCase()) continue;
    let path = u.pathname;
    if (b.path) {
      if (path !== b.path && !path.startsWith(`${b.path}/`)) continue;
      path = path.slice(b.path.length) || '/';
    }
    if (/[\\\u0000-\u001f\u007f]/.test(path) || path.startsWith('//')) return null;
    if (!routeAllowed(path)) continue;
    return `${path}${u.search}`;
  }
  return null;
}
