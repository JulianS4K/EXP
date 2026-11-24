#!/usr/bin/env bash
# Sync the vendored resale marketplace layer from JulianS4K/exos-marketplaces.
#   bash scripts/sync-marketplaces.sh <40-hex commit sha>
#   bash scripts/sync-marketplaces.sh <40-hex commit sha> --from <local checkout>
#
# Copies the paths EXP lists (PATHS in scripts/vendor-marketplaces.mjs, never
# a list from upstream) from that exact commit to the same paths here.
# Directories are replaced whole, so files removed upstream go. Symlinks,
# special files, executables and dotfiles upstream are refused before
# anything here is touched. Warns when an upstream host shim differs from
# EXP's own helper, then stamps vendor/exos-marketplaces.json with EXP's own
# copy of the stamp script, taken before the copy.
#
# --from copies from a local checkout for trying things out and does NOT
# stamp: the manifest keeps the old commit, so CI fails until a real sync.
set -euo pipefail
SHA="${1:?usage: sync-marketplaces.sh <40-hex commit sha> [--from <dir>]}"; shift
FROM=""
if [ "${1:-}" = "--from" ]; then FROM="${2:?--from needs a directory}"; fi
if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "sync-marketplaces: give the full 40-character commit sha, not a branch or tag" >&2; exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# EXP's own tooling, copied before anything is synced.
cp scripts/vendor-marketplaces.mjs "$TMP/vendor-marketplaces.mjs"
mapfile -t PATHS < <(node "$TMP/vendor-marketplaces.mjs" paths)

if [ -n "$FROM" ]; then
  git clone -q --no-checkout "$FROM" "$TMP/src"
else
  git clone -q --no-checkout https://github.com/JulianS4K/exos-marketplaces.git "$TMP/src"
fi
git -C "$TMP/src" rev-parse -q --verify "$SHA^{commit}" >/dev/null \
  || { echo "sync-marketplaces: $SHA is not a commit in the upstream repo" >&2; exit 1; }
# Refuse, from git's own tree listing, any entry that is not a plain
# non-executable file (symlink 120000, executable 100755, submodule 160000)
# at a vendored path, inside one, or at any directory above one (a symlinked
# ancestor such as src/lib would otherwise lead the copy out of the checkout).
bad="$(git -C "$TMP/src" ls-tree -r -t --full-tree "$SHA" | node -e '
  const paths = process.argv[1].split("\n").map((p) => p.replace(/\/$/, ""));
  const near = (f) => paths.some((p) => f === p || f.startsWith(p + "/") || p.startsWith(f + "/"));
  const out = [];
  for (const line of require("fs").readFileSync(0, "utf8").split("\n")) {
    const m = /^(\d{6}) (\w+) [0-9a-f]+\t(.*)$/.exec(line);
    if (!m || !near(m[3])) continue;
    const [, mode, type, f] = m;
    const base = f.split("/").pop();
    if (!(mode === "100644" || (mode === "040000" && type === "tree")) || base.startsWith(".")) out.push(mode + " " + f);
  }
  console.log(out.slice(0, 5).join("\n"));
' "$(printf '%s\n' "${PATHS[@]}")")"
if [ -n "$bad" ]; then
  echo "sync-marketplaces: refusing $SHA, it holds a symlink, executable, submodule or dot file at or above a vendored path:" >&2
  echo "$bad" >&2; exit 1
fi
# Symlinks off as a second layer: any that slipped through check out as plain files.
git -c core.symlinks=false -C "$TMP/src" checkout -q --detach "$SHA" --
SRC_REAL="$(realpath "$TMP/src")"

# Belt and braces on the checked-out tree, before touching ours. (PATHS are
# vetted by vendor-marketplaces.mjs: relative, under the marketplace areas,
# no '..' or dot segments.)
for p in "${PATHS[@]}"; do
  case "$(realpath -m "$TMP/src/${p%/}")" in
    "$SRC_REAL"/*) ;;
    *) echo "sync-marketplaces: upstream $p resolves outside the checkout" >&2; exit 1 ;;
  esac
  src="$TMP/src/${p%/}"
  if [ -L "$src" ]; then echo "sync-marketplaces: upstream $p is a symlink" >&2; exit 1; fi
  if [[ "$p" == */ ]]; then
    [ -d "$src" ] || { echo "sync-marketplaces: upstream has no directory $p" >&2; exit 1; }
    bad="$(find "$src" \( ! -type f ! -type d \) -o -type f -perm /111 -o -name '.*' | head -5)"
    if [ -n "$bad" ]; then echo "sync-marketplaces: refusing upstream $p, it holds a symlink, special, executable or dot file:" >&2; echo "$bad" >&2; exit 1; fi
  else
    [ -f "$src" ] || { echo "sync-marketplaces: upstream has no file $p" >&2; exit 1; }
    [ -x "$src" ] && { echo "sync-marketplaces: upstream $p is executable" >&2; exit 1; }
  fi
done

for p in "${PATHS[@]}"; do
  if [[ "$p" == */ ]]; then
    rm -rf -- "${p%/}"; mkdir -p -- "$(dirname "${p%/}")"; cp -R -- "$TMP/src/${p%/}" "${p%/}"
  else
    mkdir -p -- "$(dirname "$p")"; cp -- "$TMP/src/$p" "$p"
  fi
done

for h in constantTime pricing fees; do
  f="supabase/functions/_shared/$h.ts"
  cmp -s "$TMP/src/$f" "$f" || echo "warning: upstream host shim $f differs from EXP's; update it in exos-marketplaces" >&2
done
if [ -f "$TMP/src/scripts/sync-paths.txt" ] \
  && ! diff -q <(grep -v '^\s*#' "$TMP/src/scripts/sync-paths.txt" | sed 's/\s*$//' | grep -v '^$') <(printf '%s\n' "${PATHS[@]}") >/dev/null; then
  echo "warning: upstream scripts/sync-paths.txt lists different paths from EXP's PATHS; only EXP's were synced" >&2
fi

if [ -n "$FROM" ]; then
  echo "copied ${SHA:0:7} from $FROM, NOT stamped (a --from copy is not canonical; CI will fail until a real sync)"
  exit 0
fi
node "$TMP/vendor-marketplaces.mjs" stamp --commit "$SHA"
echo "synced exos-marketplaces@${SHA:0:7}; now run npm run lint, npm test and the deno checks, then commit"
