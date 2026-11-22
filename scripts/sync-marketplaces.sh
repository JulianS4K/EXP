#!/usr/bin/env bash
# Sync the vendored resale marketplace layer from JulianS4K/exos-marketplaces.
#   bash scripts/sync-marketplaces.sh <commit|branch|tag> [--from <local checkout>]
# Copies exactly the paths in the upstream scripts/sync-paths.txt to the same
# paths here (directories are replaced whole, so files removed upstream go),
# warns when an upstream host shim differs from EXP's own helper, and stamps
# vendor/exos-marketplaces.json. Then run the checks and commit the result.
set -euo pipefail
REF="${1:?usage: sync-marketplaces.sh <commit|branch|tag> [--from <dir>]}"; shift
FROM=""
if [ "${1:-}" = "--from" ]; then FROM="${2:?--from needs a directory}"; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "$FROM" ]; then
  git clone -q "$FROM" "$TMP/src"
else
  git clone -q https://github.com/JulianS4K/exos-marketplaces.git "$TMP/src"
fi
git -C "$TMP/src" checkout -q "$REF"
SHA="$(git -C "$TMP/src" rev-parse HEAD)"
PATHS="$TMP/src/scripts/sync-paths.txt"
while IFS= read -r p; do
  p="${p%%#*}"; p="$(echo "$p" | xargs)"; [ -z "$p" ] && continue
  if [[ "$p" == */ ]]; then
    rm -rf "${p%/}"; mkdir -p "$(dirname "${p%/}")"; cp -R "$TMP/src/${p%/}" "${p%/}"
  else
    mkdir -p "$(dirname "$p")"; cp "$TMP/src/$p" "$p"
  fi
done < "$PATHS"
for h in constantTime pricing fees; do
  f="supabase/functions/_shared/$h.ts"
  cmp -s "$TMP/src/$f" "$f" || echo "warning: upstream host shim $f differs from EXP's; update it in exos-marketplaces" >&2
done
cp "$PATHS" "$TMP/paths.txt"
node scripts/vendor-marketplaces.mjs stamp --commit "$SHA" --paths "$TMP/paths.txt"
echo "synced exos-marketplaces@${SHA:0:7}; now run npm run lint, npm test and the deno checks, then commit"
