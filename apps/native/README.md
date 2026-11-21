# Exos Door (iOS + Android)

The Capacitor 8 shell around the bundled Exos SPA. Everything about it (layout, building, what the SPA does
differently in the app, store rules, operator steps, fastlane lanes) is in
[`docs/native-apps.md`](../../docs/native-apps.md).

```bash
npm ci && npm run sync   # needs VITE_EXOS_WEB_URL (and the Supabase VITE_ vars); see the doc
bundle exec fastlane ios beta | android internal
```
