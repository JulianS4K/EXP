/// <reference types="vitest/config" />
import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { defineConfig, type Plugin } from 'vite';
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
      const dir = path.resolve(__dirname, 'docs/api');
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

export default defineConfig(() => {
  return {
    // Served under /bridge/ in the unified static Render env (app.py mounts
    // /bridge → static/bridge/, mirroring D0's /terminal/). Vite emits asset
    // refs as /bridge/assets/... so they resolve under the prefix. Pair with
    // <BrowserRouter basename="/bridge"> in App.tsx.
    base: '/bridge/',
    plugins: [apiSpecPlugin(), react(), tailwindcss()],
    test: {
      // .claude/** holds agent worktrees (full copies of the repo): without
      // this, a local `npm test` runs every test once per worktree.
      // vitest's defaults, spelled out so the build never loads vitest.
      exclude: ['**/node_modules/**', '**/dist/**', '**/.{idea,git,cache,output,temp}/**', '.claude/**'],
    },
    resolve: {
      alias: {
        '@': path.resolve(__dirname, '.'),
      },
    },
    server: {
      // HMR is disabled in AI Studio via DISABLE_HMR env var.
      hmr: process.env.DISABLE_HMR !== 'true',
    },
    build: {
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
