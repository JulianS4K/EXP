#!/usr/bin/env bash
# Build the SPA against the mock Supabase host, serve it, run the smoke tests.
#   npm run smoke
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
VITE_SUPABASE_URL=https://mock.supabase.test VITE_SUPABASE_ANON_KEY=anon-test npx vite build --outDir "$OUT" >/dev/null
# A preview left over from an earlier run would keep port 4174 and serve an old
# build (ours would fail --strictPort silently): refuse to start instead.
if curl -sf http://localhost:4174/bridge/ >/dev/null; then
  echo "port 4174 is already serving something; stop it first" >&2; exit 1
fi
# npx forks vite, so killing npx's pid alone leaves vite holding the port: run
# it in its own process group and kill the group.
setsid npx vite preview --outDir "$OUT" --port 4174 --strictPort >/dev/null 2>&1 &
PREVIEW=$!
trap 'kill -- -$PREVIEW 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf http://localhost:4174/bridge/ >/dev/null && break; sleep 0.5; done
node tests/smoke/smoke.mjs
