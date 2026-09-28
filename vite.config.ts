import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { defineConfig } from 'vite';

export default defineConfig(() => {
  return {
    // Served under /bridge/ in the unified static Render env (app.py mounts
    // /bridge → static/bridge/, mirroring D0's /terminal/). Vite emits asset
    // refs as /bridge/assets/... so they resolve under the prefix. Pair with
    // <BrowserRouter basename="/bridge"> in App.tsx.
    base: '/bridge/',
    plugins: [react(), tailwindcss()],
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
          // Vite 8 / Rollup 4 type `manualChunks` as a function only — the
          // object form no longer satisfies the type (TS2769).
          //
          // react/react-dom get their own long-cached vendor chunk. The two QR
          // libraries are split apart: qrcode.react (tiny, renders ticket
          // codes) and html5-qrcode (the camera scanner, dynamically imported
          // by the check-in view only). They used to share one "qr" chunk,
          // which also swallowed react and got preloaded on every page.
          manualChunks: (id: string) => {
            if (/node_modules\/(react|react-dom|scheduler)\//.test(id)) return 'react';
            if (id.includes('node_modules/@stripe/stripe-js')) return 'stripe';
            if (id.includes('node_modules/qrcode.react')) return 'qrcode';
            if (id.includes('node_modules/html5-qrcode')) return 'scanner';
            if (id.includes('node_modules/motion') || id.includes('node_modules/framer-motion') || id.includes('node_modules/motion-dom') || id.includes('node_modules/motion-utils')) return 'motion';
            return undefined;
          },
        },
      },
      chunkSizeWarningLimit: 700,
    },
  };
});
