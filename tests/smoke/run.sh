#!/usr/bin/env bash
# Build the SPA against the mock Supabase host, serve it, run the smoke tests.
#   npm run smoke
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
VITE_SUPABASE_URL=https://mock.supabase.test VITE_SUPABASE_ANON_KEY=anon-test npx vite build --outDir "$OUT" >/dev/null
npx vite preview --outDir "$OUT" --port 4174 --strictPort >/dev/null 2>&1 &
PREVIEW=$!
trap 'kill $PREVIEW 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf http://localhost:4174/bridge/ >/dev/null && break; sleep 0.5; done
node tests/smoke/smoke.mjs
