#!/usr/bin/env bash
# Build the SPA against the mock Supabase host, serve it, run the smoke tests
# and the accessibility gate (a11y.mjs).
#   npm run smoke                 (SMOKE_PORT=4175 npm run smoke to use another port)
set -euo pipefail
cd "$(dirname "$0")/../.."
PORT="${SMOKE_PORT:-4174}"
export SMOKE_BASE="${SMOKE_BASE:-http://localhost:$PORT/bridge}"
OUT=$(mktemp -d)
PREVIEW=
# The build is ~7.5 MB a run: remove it on every exit (and stop the preview).
cleanup() {
  if [ -n "$PREVIEW" ]; then kill -- -"$PREVIEW" 2>/dev/null || true; fi
  rm -rf "$OUT"
}
trap cleanup EXIT
# A test publishable key turns paid checkout on (lib/payments.ts); Stripe's page
# itself is stubbed in smoke.mjs, so nothing reaches Stripe.
VITE_SUPABASE_URL=https://mock.supabase.test VITE_SUPABASE_ANON_KEY=anon-test VITE_STRIPE_PUBLISHABLE_KEY=pk_test_smoke \
  npx vite build --outDir "$OUT" >/dev/null
# A preview left over from an earlier run would keep the port and serve an old
# build (ours would fail --strictPort silently): refuse to start instead.
if curl -sf "http://localhost:$PORT/bridge/" >/dev/null; then
  echo "port $PORT is already serving something; stop it first" >&2; exit 1
fi
# npx forks vite, so killing npx's pid alone leaves vite holding the port: run
# it in its own process group and kill the group.
setsid npx vite preview --outDir "$OUT" --port "$PORT" --strictPort >/dev/null 2>&1 &
PREVIEW=$!
for _ in $(seq 1 30); do curl -sf "http://localhost:$PORT/bridge/" >/dev/null && break; sleep 0.5; done
# Both suites run even when the first fails, so one CI run reports both.
rc=0
node tests/smoke/smoke.mjs || rc=1
node tests/smoke/a11y.mjs || rc=1
exit $rc
