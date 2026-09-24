import express, { Request, Response, NextFunction } from "express";
import { createServer as createViteServer } from "vite";
import path from "path";
import { fileURLToPath } from "url";
import crypto from "crypto";

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
  app.use((_req, res, next) => {
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
    res.setHeader(
      "Permissions-Policy",
      "camera=(self), geolocation=(), microphone=()"
    );
    if (isProd) {
      res.setHeader(
        "Strict-Transport-Security",
        "max-age=31536000; includeSubDomains"
      );
    }
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
    const configured = (process.env.VITE_APP_URL || '').replace(/\/$/, '');
    if (configured) return configured;
    const host = req.get('host') || 'localhost';
    const proto = (req.get('x-forwarded-proto') || req.protocol || 'https') as string;
    return `${proto}://${host}`;
  };

  // -- robots.txt -----------------------------------------------------------
  // Allow indexing of public surfaces, deny embed routes (those are
  // for iframe consumption, not for crawler ingestion). Points at the
  // sitemap so Googlebot finds the full event list.
  app.get('/robots.txt', (req, res) => {
    res.type('text/plain').send(
      [
        'User-agent: *',
        'Allow: /',
        'Disallow: /embed/',
        'Disallow: /api/',
        'Disallow: /dashboard',
        'Disallow: /create-event',
        'Disallow: /edit-event/',
        'Disallow: /checkin/',
        'Disallow: /onboarding',
        '',
        `Sitemap: ${publicBase(req)}/sitemap.xml`,
        '',
      ].join('\n'),
    );
  });

  // -- sitemap.xml ----------------------------------------------------------
  // Generates a sitemap pointing at every published event + every org
  // storefront. Queries the public Supabase projections (exos_public_events /
  // exos_public_orgs) with the anon key — both are anon-readable views.
  // Cached in-memory for 10 minutes so a hammering crawler doesn't
  // burn reads on every hit.
  let sitemapCache: { generatedAt: number; xml: string } | null = null;
  const SITEMAP_TTL_MS = 10 * 60 * 1000;
  app.get('/sitemap.xml', async (req, res, next) => {
    try {
      if (
        sitemapCache &&
        Date.now() - sitemapCache.generatedAt < SITEMAP_TTL_MS
      ) {
        res.type('application/xml').send(sitemapCache.xml);
        return;
      }
      // Read published events + org storefronts from the public Supabase
      // projections. exos_public_events is already status=published (the view's
      // WHERE clause) and exos_public_orgs/events are anon-readable, so the
      // anon key suffices. Lazy-import keeps dev-mode boot snappy. Absent env →
      // throws, caught below → graceful empty-sitemap stub.
      const { createClient } = await import('@supabase/supabase-js');
      const sbUrl = process.env.VITE_SUPABASE_URL;
      const sbKey = process.env.VITE_SUPABASE_ANON_KEY;
      if (!sbUrl || !sbKey) throw new Error('Supabase env (VITE_SUPABASE_URL / _ANON_KEY) missing');
      const sb = createClient(sbUrl, sbKey);
      const [{ data: events }, { data: orgs }] = await Promise.all([
        sb.from('exos_public_events').select('id, starts_at').limit(1000),
        sb.from('exos_public_orgs').select('slug').limit(500),
      ]);

      const base = publicBase(req);
      const urls: string[] = [
        `<url><loc>${base}/</loc><changefreq>daily</changefreq><priority>1.0</priority></url>`,
      ];
      for (const e of events ?? []) {
        const row = e as { id: string; starts_at?: string | null };
        const lastmod = row.starts_at ? new Date(row.starts_at).toISOString() : null;
        urls.push(
          `<url><loc>${base}/event/${row.id}</loc>${
            lastmod ? `<lastmod>${lastmod}</lastmod>` : ''
          }<changefreq>daily</changefreq><priority>0.8</priority></url>`,
        );
      }
      for (const o of orgs ?? []) {
        const slug = (o as { slug?: string }).slug;
        if (!slug) continue;
        urls.push(
          `<url><loc>${base}/o/${slug}</loc><changefreq>weekly</changefreq><priority>0.6</priority></url>`,
        );
      }
      const xml =
        '<?xml version="1.0" encoding="UTF-8"?>\n' +
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' +
        urls.join('\n') +
        '\n</urlset>\n';
      sitemapCache = { generatedAt: Date.now(), xml };
      res.type('application/xml').send(xml);
    } catch (err) {
      // Sitemap failure shouldn't 500 the whole server; serve a stub.
      res.type('application/xml').send(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>\n',
      );
      next?.(); // eslint-disable-line @typescript-eslint/no-unused-expressions
    }
  });

  // -- Vite middleware for dev / static assets in prod --------------------
  if (!isProd) {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: "spa",
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.join(process.cwd(), "dist");
    app.use(
      express.static(distPath, {
        // Hashed assets are immutable — let CDNs cache them aggressively.
        // index.html is served below with no-cache so the user always gets
        // a fresh entrypoint.
        setHeaders: (res, filePath) => {
          if (/\.[a-f0-9]{8,}\./.test(filePath)) {
            res.setHeader(
              "Cache-Control",
              "public, max-age=31536000, immutable"
            );
          }
        },
      })
    );

    app.get("*", (_req, res) => {
      res.setHeader("Cache-Control", "no-cache");
      res.sendFile(path.join(distPath, "index.html"));
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
