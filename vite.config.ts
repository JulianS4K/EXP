/// <reference types="vitest/config" />
import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import fs from 'fs';
import path from 'path';
import { defineConfig, loadEnv, type Plugin } from 'vite';
import { buildSpecFiles } from './scripts/api-spec.mjs';

/**
 * Generates public/api-spec.json and public/openapi.json (the /developers
 * reference) from docs/api/*.json via scripts/api-spec.mjs before any build,
 * and again under the dev server when a spec file changes. A spec that does
 * not validate fails the build; in dev it is logged and the last good files
 * stay. Skipped under vitest (src/lib/apiReference.test.ts validates instead).
 */
function apiSpecPlugin(): Plugin {
  let command: 'build' | 'serve' = 'build';
  return {
    name: 'exos-api-spec',
    configResolved(c) {
      command = c.command;
    },
    buildStart() {
      if (process.env.VITEST) return;
      try {
        buildSpecFiles();
      } catch (err) {
        if (command === 'build') this.error((err as Error).message);
        this.warn((err as Error).message);
      }
    },
    configureServer(server) {
      if (process.env.VITEST) return;
      const dir = path.resolve(import.meta.dirname, 'docs/api');
      server.watcher.add(dir);
      server.watcher.on('change', (file) => {
        if (!file.startsWith(dir) || !file.endsWith('.json')) return;
        try {
          buildSpecFiles();
          server.config.logger.info('[exos-api-spec] regenerated public/api-spec.json');
        } catch (err) {
          server.config.logger.error((err as Error).message);
        }
      });
    },
  };
}

/**
 * `vite build --mode native`: the bundle the Exos Door app ships
 * (apps/native, docs/native-apps.md). It is served by Capacitor from the
 * app's own origin root (capacitor://localhost/, https://localhost/), so the
 * base is '/' and the router has no basename. (Not './': BrowserRouter deep
 * routes would then resolve assets under the route's path.) Output goes to
 * apps/native/www; the service worker is left out (the app is the offline
 * shell). VITE_EXOS_WEB_URL, the public web app (https://host/bridge), is
 * required: every link that leaves the app (Stripe's return pages, shares,
 * auth mails) is built from it.
 */
function nativeShellPlugin(): Plugin {
  let outDir = '';
  return {
    name: 'exos-native-shell',
    configResolved(c) {
      outDir = path.resolve(c.root, c.build.outDir);
    },
    closeBundle() {
      fs.rmSync(path.join(outDir, 'sw.js'), { force: true });
    },
  };
}

export default defineConfig(({ mode }) => {
  const native = mode === 'native';
  if (native && !process.env.VITEST) {
    const env = loadEnv(mode, import.meta.dirname, 'VITE_');
    const webUrl = (process.env.VITE_EXOS_WEB_URL ?? env.VITE_EXOS_WEB_URL ?? '').trim();
    if (!/^https:\/\/[^/?#\s]+(\/[^?#\s]*)?$/.test(webUrl)) {
      throw new Error('vite --mode native needs VITE_EXOS_WEB_URL: the public web app, e.g. https://exos-web.onrender.com/bridge (docs/native-apps.md).');
    }
  }
  return {
    // Served under /bridge/ in the unified static Render env (app.py mounts
    // /bridge → static/bridge/, mirroring D0's /terminal/). Vite emits asset
    // refs as /bridge/assets/... so they resolve under the prefix. Pair with
    // <BrowserRouter basename="/bridge"> in App.tsx. The native app: '/'.
    base: native ? '/' : '/bridge/',
    plugins: [apiSpecPlugin(), react(), tailwindcss(), ...(native ? [nativeShellPlugin()] : [])],
    test: {
      // .claude/** holds agent worktrees (full copies of the repo): without
      // this, a local `npm test` runs every test once per worktree.
      // vitest's defaults, spelled out so the build never loads vitest.
      exclude: ['**/node_modules/**', '**/dist/**', '**/.{idea,git,cache,output,temp}/**', '.claude/**'],
    },
    resolve: {
      alias: {
        '@': path.resolve(import.meta.dirname, '.'),
        // src/main.tsx's platform installer: a no-op on the web, the
        // Capacitor adapters in the native app (resolved from
        // apps/native/node_modules, never the root package.json).
        '@exos/platform-install': path.resolve(
          import.meta.dirname,
          native ? 'apps/native/src/install.ts' : 'src/lib/platform/install.web.ts',
        ),
      },
    },
    server: {
      // HMR is disabled in AI Studio via DISABLE_HMR env var.
      hmr: process.env.DISABLE_HMR !== 'true',
    },
    build: {
      outDir: native ? 'apps/native/www' : 'dist',
      emptyOutDir: true,
      // Split heavy deps into their own chunks so they can be cached
      // independently and the initial route doesn't drag them in.
      // Combined with React.lazy() routes in App.tsx this lowers the
      // entry chunk size considerably.
      rollupOptions: {
        output: {
          // Vite 8 bundles with Rolldown, whose chunk groups (codeSplitting)
          // replace the deprecated manualChunks. Each group also pulls in its
          // modules' dependencies, so `priority` decides who owns a shared
          // dep: react has to win, or it lands inside whichever library group
          // reached it first (it used to ride in the "qr" chunk).
          //
          // react/react-dom get their own long-cached vendor chunk. The two QR
          // libraries are split apart: qrcode.react (small, renders ticket
          // codes) and html5-qrcode (the camera scanner, dynamically imported
          // by the check-in view only). They used to share one "qr" chunk
          // that was preloaded on every page.
          codeSplitting: {
            groups: [
              { name: 'react', test: /node_modules[\\/](react|react-dom|scheduler)[\\/]/, priority: 40 },
              { name: 'stripe', test: /node_modules[\\/]@stripe[\\/]stripe-js[\\/]/, priority: 30 },
              { name: 'qrcode', test: /node_modules[\\/]qrcode\.react[\\/]/, priority: 30 },
              { name: 'scanner', test: /node_modules[\\/]html5-qrcode[\\/]/, priority: 30 },
              { name: 'motion', test: /node_modules[\\/](motion|framer-motion|motion-dom|motion-utils)[\\/]/, priority: 20 },
            ],
          },
        },
      },
      chunkSizeWarningLimit: 700,
    },
  };
});
