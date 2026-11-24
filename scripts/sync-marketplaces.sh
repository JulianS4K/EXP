#!/usr/bin/env bash
# Sync the vendored resale marketplace layer from JulianS4K/exos-marketplaces.
#   bash scripts/sync-marketplaces.sh <40-hex commit sha>
#   bash scripts/sync-marketplaces.sh <40-hex commit sha> --from <local checkout>
#   ... --allow-downgrade   (permit a commit that does not descend from the pinned one)
#
# Copies the paths EXP lists (PATHS in scripts/vendor-marketplaces.mjs, never
# a list from upstream) from that exact commit, which must be on upstream's
# default branch, to the same paths here. Files come straight from git's
# blobs (no checkout: no symlinks, no .gitattributes rewriting), and the
# commit is refused whole, before anything here changes, if any entry at,
# inside or above a vendored path is a symlink, executable, submodule or
# dotfile. Directories are replaced whole, so files removed upstream go.
# Warns when an upstream host shim differs from EXP's own helper, then stamps
# vendor/exos-marketplaces.json with EXP's own stamp script, copied first.
#
# --from copies from a local repo for trying things out and does NOT stamp:
# the manifest keeps the old commit, so CI fails until a real sync.
set -euo pipefail
SHA="${1:?usage: sync-marketplaces.sh <40-hex commit sha> [--from <dir>] [--allow-downgrade]}"; shift
FROM=""; DOWNGRADE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:?--from needs a directory}"; shift 2 ;;
    --allow-downgrade) DOWNGRADE=1; shift ;;
    *) echo "sync-marketplaces: unknown option $1" >&2; exit 2 ;;
  esac
done
if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "sync-marketplaces: give the full 40-character commit sha, not a branch or tag" >&2; exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# EXP's own tooling, copied before anything is synced.
VM="$TMP/vendor-marketplaces.mjs"
cp scripts/vendor-marketplaces.mjs "$VM"
LIST="$(node "$VM" paths)"
mapfile -t PATHS <<<"$LIST"
[ "${#PATHS[@]}" -gt 0 ] && [ -n "${PATHS[0]}" ] || { echo "sync-marketplaces: no vendored paths" >&2; exit 1; }

UP="$TMP/up.git"
if [ -n "$FROM" ]; then
  git clone -q --bare "$FROM" "$UP"
else
  git clone -q --bare https://github.com/JulianS4K/exos-marketplaces.git "$UP"
fi
# A commit object itself (an annotated tag's sha peels to a different one).
[ "$(git --git-dir "$UP" rev-parse -q --verify "$SHA^{commit}" 2>/dev/null)" = "$SHA" ] \
  || { echo "sync-marketplaces: $SHA is not a commit in the upstream repo" >&2; exit 1; }
git --git-dir "$UP" merge-base --is-ancestor "$SHA" HEAD \
  || { echo "sync-marketplaces: $SHA is not on upstream's default branch" >&2; exit 1; }
# No downgrades: the new commit must descend from the pinned one.
OLD="$(node -e 'console.log(JSON.parse(require("fs").readFileSync("vendor/exos-marketplaces.json","utf8")).commit)')"
if [ -z "$DOWNGRADE" ] && ! git --git-dir "$UP" merge-base --is-ancestor "$OLD" "$SHA" 2>/dev/null; then
  echo "sync-marketplaces: $SHA does not descend from the pinned ${OLD:0:7}; pass --allow-downgrade if that is intended" >&2; exit 1
fi

STAGE="$TMP/stage"
node "$VM" extract --git-dir "$UP" --commit "$SHA" --out "$STAGE"

for p in "${PATHS[@]}"; do
  if [[ "$p" == */ ]]; then
    rm -rf -- "${p%/}"; mkdir -p -- "$(dirname "${p%/}")"; cp -R -- "$STAGE/${p%/}" "${p%/}"
  else
    mkdir -p -- "$(dirname "$p")"; cp -- "$STAGE/$p" "$p"
  fi
done

for h in constantTime pricing fees; do
  f="supabase/functions/_shared/$h.ts"
  git --git-dir "$UP" cat-file blob "$SHA:$f" 2>/dev/null | cmp -s - "$f" \
    || echo "warning: upstream host shim $f differs from EXP's (or is missing); update it in exos-marketplaces" >&2
done
if UPLIST="$(git --git-dir "$UP" cat-file blob "$SHA:scripts/sync-paths.txt" 2>/dev/null)" \
  && [ "$(printf '%s\n' "$UPLIST" | sed -e 's/#.*//' -e 's/[[:space:]]*$//' | grep -v '^$')" != "$LIST" ]; then
  echo "warning: upstream scripts/sync-paths.txt lists different paths from EXP's PATHS; only EXP's were synced" >&2
fi

if [ -n "$FROM" ]; then
  echo "copied ${SHA:0:7} from $FROM, NOT stamped (a --from copy is not canonical; CI will fail until a real sync)"
  exit 0
fi
node "$VM" stamp --commit "$SHA"
echo "synced exos-marketplaces@${SHA:0:7}; now run npm run lint, npm test and the deno checks, then commit"
