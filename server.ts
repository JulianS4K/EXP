import express, { Request, Response, NextFunction } from "express";
import { createServer as createViteServer } from "vite";
import path from "path";
import { fileURLToPath } from "url";
import crypto from "crypto";
import fs from "fs";
import { securityHeaders } from "./src/lib/hosting/headers";
import { isLinkCrawler } from "./src/lib/hosting/crawler";
import { domainRedirect, hostOnly, isPrimary, primaryHosts, ttlCache } from "./src/lib/hosting/domains";
import { buildLlmsTxt, buildPreviewPage, buildSitemap, inject, injectBody, previewTarget, type PromoterReader, type PublicReader } from "./src/lib/hosting/seo";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ---------------------------------------------------------------------------
// Production hardening notes (vs. the original prototype):
//   * Reads PORT from env (PaaS like Cloud Run/Render require this).
//   * Caps JSON body size — defends against trivial OOM payloads.
//   * Adds basic security headers without pulling in Helmet (kept dep-light).
//   * Adds a request id + structured access log on every request.
//   * Adds /healthz so a load balancer can probe liveness.
//   * Catches uncaught route errors centrally instead of leaking stacks.
//   * Handles SIGTERM/SIGINT cleanly so in-flight requests don't get cut off.
// Payments are not served from here: checkout is the `exos-checkout` edge
// function and fulfillment is `stripe-webhook`. The old /api/* Stripe routes
// were removed (audit 2026-09-24): unused, and /api/verify-session returned
// any session's metadata to anyone holding its id.
// ---------------------------------------------------------------------------

// Parse the CORS allowlist from CORS_ORIGINS (comma-separated). Empty list
// → same-origin only (no Access-Control-Allow-Origin emitted, which makes
// browsers refuse cross-origin reads from anywhere).
function parseAllowlist(): Set<string> {
  const raw = process.env.CORS_ORIGINS || '';
  return new Set(raw.split(',').map((s) => s.trim()).filter(Boolean));
}

async function startServer() {
  const app = express();
  const PORT = Number(process.env.PORT) || 3000;
  const HOST = process.env.HOST || "0.0.0.0";
  const isProd = process.env.NODE_ENV === "production";
  // AI discovery (docs/hosting.md "AI discovery"): AI crawlers and fetchers
  // treated as link crawlers, full event pages for crawlers, FAQ JSON-LD and
  // /llms.txt. Off until launch: set EXOS_AI_DISCOVERY=on to turn it on.
  const aiDiscovery = process.env.EXOS_AI_DISCOVERY === "on";
  const corsAllowlist = parseAllowlist();

  // If the SPA and API are on the same origin (default for `npm start`),
  // CORS is not needed and the allowlist stays empty. Set CORS_ORIGINS to a
  // comma-separated list when deploying the API on a different hostname.
  app.use((req, res, next) => {
    const origin = req.header('Origin');
    if (origin && corsAllowlist.has(origin)) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
      res.setHeader('Access-Control-Max-Age', '600');
    }
    if (req.method === 'OPTIONS') {
      // Short-circuit preflight only when origin is allowed; otherwise the
      // missing CORS headers will cause the browser to block — which is the
      // correct behaviour.
      return res.status(origin && corsAllowlist.has(origin) ? 204 : 403).end();
    }
    return next();
  });

  // -- Security headers ----------------------------------------------------
  // Minimal set of headers that any web app should send. We don't ship a
  // strict CSP yet because the SPA pulls Stripe.js + Firebase from CDNs and
  // a misconfigured CSP would silently break checkout. Add one once the
  // origin allowlist is known.
  // Behind Render's proxy, plus Terminal-2's /bridge reverse proxy when the
  // app is reached through the Render link: trust that many X-Forwarded-For
  // hops so req.ip (rate limits, logs) is the real client.
  app.set("trust proxy", Number(process.env.TRUST_PROXY_HOPS ?? 1));

  // Production gets the per-page /bridge policy that Terminal-2 used to set
  // (src/lib/hosting/headers.ts: CSP, camera for the door scanner, framing
  // only for the embed). Dev keeps the loose set so Vite's HMR still works.
  app.use((req, res, next) => {
    if (isProd) {
      const q = req.originalUrl.indexOf("?");
      const search = q >= 0 ? req.originalUrl.slice(q) : "";
      for (const [k, v] of Object.entries(securityHeaders(req.path, { hsts: true, search }))) res.setHeader(k, v);
      return next();
    }
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
    res.setHeader("Permissions-Policy", "camera=(self), geolocation=(), microphone=()");
    next();
  });

  // -- Request id + access log --------------------------------------------
  app.use((req, res, next) => {
    const requestId =
      (req.header("x-request-id") as string | undefined) ||
      crypto.randomUUID();
    res.setHeader("X-Request-Id", requestId);
    (req as Request & { id: string }).id = requestId;

    const start = Date.now();
    res.on("finish", () => {
      const ms = Date.now() - start;
      // One-line structured log; easy to parse from any log aggregator.
      console.log(
        JSON.stringify({
          t: new Date().toISOString(),
          lvl: "info",
          reqId: requestId,
          method: req.method,
          path: req.originalUrl,
          status: res.statusCode,
          ms,
        })
      );
    });
    next();
  });

  // -- ActivityPub (docs/federation.md) -------------------------------------
  // With EXOS_FEDERATION=on, the fediverse paths are reverse-proxied to the
  // exos-activitypub edge function. The path is kept as is (inbound HTTP
  // signatures cover it) and the body is passed through raw (they cover its
  // digest too), so this runs before express.json. Off: these paths 404 as before.
  if (process.env.EXOS_FEDERATION === 'on') {
    const fnBase = `${(process.env.VITE_SUPABASE_URL || '').replace(/\/+$/, '')}/functions/v1/exos-activitypub`;
    const isAp = (p: string) =>
      p === '/.well-known/webfinger' || p === '/.well-known/nodeinfo' || p.startsWith('/nodeinfo/') || p.startsWith('/ap/');
    const pass = ['accept', 'content-type', 'date', 'digest', 'signature', 'user-agent', 'if-none-match'];
    app.use(async (req, res, next) => {
      if (!isAp(req.path)) return next();
      if (!/^https:\/\//.test(fnBase)) return res.status(503).type('text/plain').send('federation not configured');
      if (req.method !== 'GET' && req.method !== 'HEAD' && req.method !== 'POST') return res.status(405).end();
      try {
        let body: Buffer | undefined;
        if (req.method === 'POST') {
          const chunks: Buffer[] = [];
          let size = 0;
          for await (const c of req) {
            size += (c as Buffer).length;
            if (size > 256 * 1024) return res.status(413).type('text/plain').send('payload too large');
            chunks.push(c as Buffer);
          }
          body = Buffer.concat(chunks);
        }
        const headers: Record<string, string> = { 'x-forwarded-for': req.ip || '' };
        for (const h of pass) {
          const v = req.get(h);
          if (v) headers[h] = v;
        }
        const r = await fetch(fnBase + req.originalUrl, {
          method: req.method, headers, body, redirect: 'manual', signal: AbortSignal.timeout(20_000),
        });
        res.status(r.status);
        for (const h of ['content-type', 'cache-control', 'location', 'etag', 'retry-after', 'access-control-allow-origin']) {
          const v = r.headers.get(h);
          if (v) res.setHeader(h, v);
        }
        res.send(Buffer.from(await r.arrayBuffer()));
      } catch (err) {
        next(err);
      }
    });
  }

  // -- Body parsing with a sane cap ---------------------------------------
  // 100kb is plenty for the API's JSON payloads. If something legitimately
  // larger comes along (e.g. ticket batch ops) raise it on a per-route basis.
  app.use(express.json({ limit: "100kb" }));

  // -- Health check (used by load balancers, uptime monitors) -------------
  app.get("/healthz", (_req, res) => {
    res.status(200).json({ status: "ok", uptime: process.uptime() });
  });

  // Canonical public base URL for crawler-facing absolute links. Pinned to
  // VITE_APP_URL (same env Stripe redirect URLs use) so a forged Host /
  // X-Forwarded-Proto header can't poison robots.txt or the cached sitemap.
  // Request-header fallback is dev-only convenience when the env is unset.
  const publicBase = (req: express.Request): string => {
    const configured = (process.env.EXOS_PUBLIC_BASE_URL || process.env.VITE_APP_URL || '').replace(/\/+$/, '').replace(/\/bridge$/, '');
    if (configured) return configured;
    const host = req.get('host') || 'localhost';
    const proto = (req.get('x-forwarded-proto') || req.protocol || 'https') as string;
    return `${proto}://${host}`;
  };

  // -- Public views reader (link previews + sitemap) ----------------------
  // Anon key + the exos_public_* projections only: published events, public
  // tiers, public orgs. Nothing here can read private data.
  let reader: PublicReader | null | undefined;
  let promoterReader: PromoterReader | undefined;
  const getReader = async (): Promise<PublicReader | null> => {
    if (reader !== undefined) return reader;
    const sbUrl = process.env.VITE_SUPABASE_URL;
    const sbKey = process.env.VITE_SUPABASE_ANON_KEY;
    if (!sbUrl || !sbKey) return (reader = null);
    const { createClient } = await import('@supabase/supabase-js');
    const sb = createClient(sbUrl, sbKey, { auth: { persistSession: false } });
    reader = async (table, cols, filter, limit, opts) => {
      let q = sb.from(table).select(cols);
      if (filter) q = q.eq(filter.col, filter.val);
      if (opts?.gte) q = q.gte(opts.gte.col, opts.gte.val);
      if (opts?.order) q = q.order(opts.order, { ascending: true });
      const { data, error } = await q.limit(limit);
      if (error) throw error;
      return (data ?? []) as unknown as Array<Record<string, unknown>>;
    };
    promoterReader = async (orgSlug, code) => {
      const { data, error } = await sb.rpc('exos_public_promoter', { p_org_slug: orgSlug, p_code: code });
      if (error || !data) return null;
      const name = (data as { promoter?: { name?: unknown } }).promoter?.name;
      return typeof name === 'string' && name.trim() ? name.trim() : null;
    };
    return reader;
  };

  // -- Custom domains (mig 20261016130000) -----------------------------------
  // tickets.venue.com: a verified org domain serves this app; its bare root
  // goes to the org's storefront. Lookups are cached for 5 minutes.
  const primaries = primaryHosts(process.env.EXOS_PUBLIC_BASE_URL, (process.env.EXOS_PRIMARY_HOSTS ?? '').split(',').filter(Boolean));
  const domainSlugs = ttlCache<string | null>(5 * 60_000);
  app.use(async (req, res, next) => {
    const host = hostOnly(req.get('host'));
    if (!host || isPrimary(host, primaries) || (req.method !== 'GET' && req.method !== 'HEAD')) return next();
    if (req.path !== '/' && req.path !== '/bridge' && req.path !== '/bridge/') return next();
    let slug = domainSlugs.get(host);
    if (slug === undefined) {
      slug = null;
      try {
        const sbUrl = process.env.VITE_SUPABASE_URL;
        const sbKey = process.env.VITE_SUPABASE_ANON_KEY;
        if (sbUrl && sbKey) {
          const { createClient } = await import('@supabase/supabase-js');
          const sb = createClient(sbUrl, sbKey, { auth: { persistSession: false } });
          const { data } = await sb.from('exos_public_org_domains').select('org_slug').eq('domain', host).maybeSingle();
          slug = (data as { org_slug?: string } | null)?.org_slug ?? null;
        }
      } catch {
        slug = null;
      }
      domainSlugs.set(host, slug);
    }
    const to = domainRedirect(req.path, slug);
    return to ? res.redirect(302, to) : next();
  });

  // -- robots.txt -----------------------------------------------------------
  // On this host the app lives under /bridge/ (vite base). Through the Render
  // link, Terminal-2 serves its own robots.txt and only proxies /bridge/*,
  // which is why the sitemap lives at /bridge/sitemap.xml.
  app.get('/robots.txt', (req, res) => {
    res.type('text/plain').send(
      [
        'User-agent: *',
        'Allow: /bridge/',
        'Disallow: /bridge/embed/',
        'Disallow: /bridge/dashboard',
        'Disallow: /bridge/create-event',
        'Disallow: /bridge/edit-event/',
        'Disallow: /bridge/checkin/',
        'Disallow: /bridge/onboarding',
        '',
        `Sitemap: ${publicBase(req)}/bridge/sitemap.xml`,
        '',
      ].join('\n'),
    );
  });

  // -- sitemap.xml ----------------------------------------------------------
  // Published events that haven't ended + organizer pages
  // (src/lib/hosting/seo.ts buildSitemap), cached 10 minutes.
  let sitemapCache: { generatedAt: number; xml: string } | null = null;
  const SITEMAP_TTL_MS = 10 * 60 * 1000;
  app.get('/bridge/sitemap.xml', async (req, res) => {
    try {
      if (!sitemapCache || Date.now() - sitemapCache.generatedAt >= SITEMAP_TTL_MS) {
        const read = await getReader();
        if (!read) return res.status(404).type('text/plain').send('not found');
        sitemapCache = { generatedAt: Date.now(), xml: await buildSitemap(read, publicBase(req)) };
      }
      return res.type('application/xml').send(sitemapCache.xml);
    } catch (err) {
      console.error(JSON.stringify({ lvl: 'error', msg: 'sitemap failed', error: String(err) }));
      return res.status(503).type('text/plain').send('sitemap unavailable');
    }
  });
  app.get('/sitemap.xml', (_req, res) => res.redirect(301, '/bridge/sitemap.xml'));

  // -- llms.txt (AI discovery only; a plain 404 until launch) --------------
  if (aiDiscovery) {
    let llmsCache: { generatedAt: number; base: string; text: string } | null = null;
    const sendLlms = async (req: Request, res: Response) => {
      try {
        const base = publicBase(req);
        if (!llmsCache || llmsCache.base !== base || Date.now() - llmsCache.generatedAt >= SITEMAP_TTL_MS) {
          const read = await getReader();
          if (!read) return res.status(404).type('text/plain').send('not found');
          const sb = (process.env.VITE_SUPABASE_URL || '').replace(/\/+$/, '');
          const mcpUrl = /^https:\/\//.test(sb) ? `${sb}/functions/v1/exos-mcp` : null;
          llmsCache = { generatedAt: Date.now(), base, text: await buildLlmsTxt(read, base, { mcpUrl }) };
        }
        return res.type('text/plain; charset=utf-8').send(llmsCache.text);
      } catch (err) {
        console.error(JSON.stringify({ lvl: 'error', msg: 'llms.txt failed', error: String(err) }));
        return res.status(503).type('text/plain').send('unavailable');
      }
    };
    app.get('/llms.txt', sendLlms);
    app.get('/bridge/llms.txt', sendLlms);
  }

  if (!isProd) {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: "spa",
    });
    app.use(vite.middlewares);
  } else {
    // The app is built with vite base '/bridge/' and <Router basename="/bridge">,
    // so it's served under /bridge/ here too. That keeps one set of URLs whether
    // a visitor comes straight to this service or through the Render link
    // (Terminal-2 reverse-proxies /bridge/* here, same origin, shared login).
    const distPath = path.join(process.cwd(), "dist");
    const indexPath = path.join(distPath, "index.html");
    let shell: string | null = null;
    const getShell = () => (shell ??= fs.readFileSync(indexPath, "utf8"));

    const withQuery = (req: Request, target: string) => {
      const q = req.originalUrl.indexOf("?");
      return q === -1 ? target : target + req.originalUrl.slice(q);
    };
    app.get("/", (req, res) => res.redirect(308, withQuery(req, "/bridge/")));
    // Express matches "/bridge" and "/bridge/" alike (non-strict routing), so
    // only redirect the bare form or this would loop.
    app.get("/bridge", (req, res, next) =>
      req.originalUrl.split("?")[0] === "/bridge" ? res.redirect(308, withQuery(req, "/bridge/")) : next(),
    );
    app.use(
      "/bridge",
      express.static(distPath, {
        index: false,
        // Hashed assets are immutable — let CDNs cache them aggressively.
        // index.html is served below with no-cache so the user always gets
        // a fresh entrypoint.
        setHeaders: (res, filePath) => {
          if (/\.[a-f0-9]{8,}\./.test(filePath) || /-[A-Za-z0-9_-]{8,}\.(js|css)$/.test(filePath)) {
            res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
          }
        },
      })
    );

    // A missing asset is a 404, not the SPA shell (a stale chunk request
    // must fail loudly instead of parsing HTML as JS).
    const ASSET_EXT = /\.(js|mjs|css|map|json|svg|png|jpe?g|webp|ico|woff2?|txt|webmanifest)$/i;

    app.get("/bridge/*", async (req, res, next) => {
      if (ASSET_EXT.test(req.path)) return next();
      res.setHeader("Cache-Control", "no-cache");
      // Link-unfurl bots don't run JS: give them the event / org preview
      // server-side. Humans get the plain shell. A failed preview must never
      // break the page.
      if (isLinkCrawler(req.get("user-agent"), { ai: aiDiscovery })) {
        try {
          const page = req.path.replace(/^\/bridge\//, "");
          const query = req.originalUrl.includes("?") ? req.originalUrl.slice(req.originalUrl.indexOf("?") + 1) : "";
          const target = previewTarget(page, query);
          const read = target ? await getReader() : null;
          const preview = target && read ? await buildPreviewPage(read, target, publicBase(req), { content: aiDiscovery, promoter: promoterReader }) : null;
          if (preview) return res.type("html").send(injectBody(inject(getShell(), preview.tags), preview.body));
        } catch (err) {
          console.error(JSON.stringify({ lvl: "error", msg: "link preview failed", path: req.path, error: String(err) }));
        }
      }
      res.sendFile(indexPath);
    });
  }

  // -- Central error handler ---------------------------------------------
  // Express has to recognise the four-arg signature for this to fire.
  app.use((err: any, req: Request, res: Response, _next: NextFunction) => {
    const reqId = (req as Request & { id?: string }).id;
    console.error(
      JSON.stringify({
        t: new Date().toISOString(),
        lvl: "error",
        reqId,
        path: req.originalUrl,
        message: err?.message,
        stack: err?.stack,
      })
    );
    if (res.headersSent) return;
    // Don't leak internal error messages to clients in production.
    res
      .status(500)
      .json({ error: isProd ? "Internal Server Error" : err?.message });
  });

  const server = app.listen(PORT, HOST, () => {
    console.log(`Server running on http://${HOST}:${PORT}`);
  });

  // -- Graceful shutdown --------------------------------------------------
  // PaaS sends SIGTERM on deploy/scale-down; finishing in-flight requests
  // before exiting prevents 502s during rollouts.
  const shutdown = (signal: NodeJS.Signals) => {
    console.log(`Received ${signal}, shutting down gracefully...`);
    server.close((err) => {
      if (err) {
        console.error("Error during shutdown", err);
        process.exit(1);
      }
      process.exit(0);
    });
    // Hard-kill backstop in case something hangs forever.
    setTimeout(() => {
      console.error("Forcing exit after 10s shutdown timeout");
      process.exit(1);
    }, 10_000).unref();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

startServer().catch((err) => {
  console.error("Failed to start server", err);
  process.exit(1);
});
