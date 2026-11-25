#!/usr/bin/env bash
set -eu

if [ $# -ne 2 ] || [ -z "$2" ]; then
  echo "usage: $0 <venture-dir> \"<venture name>\"" >&2
  exit 64
fi

dir=$1
name=$2
skill_dir=$(cd "$(dirname "$0")/.." && pwd)
assets="$skill_dir/assets"
today=$(date +%F)
files="CLAUDE.md VENTURE.md RESEARCH.md LOG.md ERRORS.md"

mkdir -p "$dir"
for f in $files; do
  if [ -e "$dir/$f" ]; then
    echo "refusing: $dir/$f exists. Resume the venture instead of re-creating it." >&2
    exit 1
  fi
done

safe_name=$(printf '%s' "$name" | sed -e 's/[\\&|]/\\&/g')

stage=$(mktemp -d "$dir/.venture-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
for f in $files; do
  sed -e "s|<venture name>|$safe_name|g" -e "s|<YYYY-MM-DD>|$today|g" \
    "$assets/$f.template" > "$stage/$f"
done
for f in $files; do
  mv "$stage/$f" "$dir/$f"
done

if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$dir" init -q 2>/dev/null; then
    echo "initialised git in $dir"
  else
    echo "note: git not available; venture files are not under version control"
  fi
fi

echo "created $files in $dir for \"$name\""
echo "next: phase 1 Idea (references/idea-and-validation.md). No code, no research yet."
