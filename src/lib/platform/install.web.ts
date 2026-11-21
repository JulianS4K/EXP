// The web build's platform installer: nothing to install, the web defaults in
// ./adapters stand. `vite build --mode native` swaps this module for
// apps/native/src/install.ts (vite.config.ts, alias @exos/platform-install),
// which registers the Capacitor-backed adapters. Called once, before React
// mounts (src/main.tsx).

export function installPlatform(): void {
  /* web: no-op */
}
