#!/usr/bin/env node
// The resale marketplace layer is vendored from JulianS4K/exos-marketplaces
// (the source of truth) at the same paths. vendor/exos-marketplaces.json pins
// the upstream commit and a fingerprint of every vendored file. The list of
// vendored paths is PATHS below, owned by EXP: an upstream repo never decides
// what gets written here, and dropping a path is a reviewed edit to this file.
//
//   node scripts/vendor-marketplaces.mjs check
//       CI: the vendored files are exactly the pinned ones (no local edits,
//       nothing added or removed), the manifest lists exactly PATHS, and
//       every vendored file is a regular, non-executable file.
//   node scripts/vendor-marketplaces.mjs paths
//       Prints PATHS, one per line (used by scripts/sync-marketplaces.sh).
//   node scripts/vendor-marketplaces.mjs stamp --commit <sha>
//       Used by scripts/sync-marketplaces.sh after copying a new commit in.
//
// The check proves the files match the manifest, not that the manifest
// matches upstream: someone could edit a file and re-stamp. Review catches
// that; a re-stamp without a sync shows up as a manifest change with no
// matching upstream commit.
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { posix } from 'node:path';

const MANIFEST = 'vendor/exos-marketplaces.json';
const REPO = 'JulianS4K/exos-marketplaces';
export const PATHS = [
  'supabase/functions/_shared/marketplace/',
  'docs/marketplace/',
  'src/lib/marketplace/index.ts',
  'src/lib/marketplace/stubhub/',
  'src/lib/marketplace/seatgeek/',
  'src/lib/marketplace/vivid/',
  'src/lib/marketplace/tevo/',
  'src/lib/marketplace/gametime/',
  'src/lib/marketplace/gotickets/',
  'src/lib/marketplace/channels.test.ts',
  'src/lib/marketplace/eventStandard.test.ts',
  'src/lib/marketplace/fees.test.ts',
  'src/lib/marketplace/listingStandard.test.ts',
  'src/lib/marketplace/netError.test.ts',
  'src/lib/marketplace/sales.test.ts',
  'src/lib/marketplace/sync.test.ts',
  'src/lib/marketplace/transferStock.test.ts',
];
const PREFIXES = ['supabase/functions/_shared/marketplace/', 'docs/marketplace/', 'src/lib/marketplace/'];

function fail(msg) {
  console.error(msg);
  process.exit(1);
}
// Every path stays inside the vendored areas: relative, no '..', no dot
// segments, under one of PREFIXES.
for (const p of PATHS) {
  const segs = p.replace(/\/$/, '').split('/');
  if (p.startsWith('/') || segs.some((s) => s === '' || s === '.' || s === '..' || s.startsWith('.'))
    || !PREFIXES.some((x) => p.startsWith(x))) fail(`vendor-marketplaces: bad path ${p}`);
}

// Walk without following links; anything but a directory or a regular,
// non-executable file fails closed. Paths are always '/'-joined.
function walk(d) {
  return readdirSync(d).sort().flatMap((f) => {
    const p = posix.join(d, f);
    const st = lstatSync(p);
    if (st.isDirectory()) return walk(p);
    if (!st.isFile()) fail(`vendor-marketplaces: ${p} is not a regular file (symlinks and special files are refused)`);
    if (st.mode & 0o111) fail(`vendor-marketplaces: ${p} is executable; vendored files must not be`);
    return [p];
  });
}
function filesOf(paths) {
  return paths.flatMap((p) => {
    const q = p.endsWith('/') ? p.slice(0, -1) : p;
    if (!existsSync(q)) return [];
    const st = lstatSync(q);
    if (p.endsWith('/')) {
      if (!st.isDirectory()) fail(`vendor-marketplaces: ${q} should be a directory`);
      return walk(q);
    }
    if (!st.isFile()) fail(`vendor-marketplaces: ${q} is not a regular file`);
    return [q];
  }).sort();
}
const sha = (b) => createHash('sha256').update(b).digest('hex');
function fingerprint(paths) {
  const files = filesOf(paths);
  const lines = files.map((f) => `${f}\0${sha(readFileSync(f))}`);
  return { files: files.length, sha256: sha(lines.join('\n')) };
}

const [cmd, ...args] = process.argv.slice(2);
const arg = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };

if (cmd === 'paths') {
  console.log(PATHS.join('\n'));
} else if (cmd === 'stamp') {
  const commit = arg('--commit');
  if (!/^[0-9a-f]{40}$/.test(commit ?? '')) {
    console.error('usage: stamp --commit <40-hex sha>');
    process.exit(2);
  }
  const fp = fingerprint(PATHS);
  writeFileSync(MANIFEST, JSON.stringify({ repo: REPO, commit, paths: PATHS, files: fp.files, sha256: fp.sha256 }, null, 2) + '\n');
  console.log(`stamped ${MANIFEST}: ${REPO}@${commit.slice(0, 7)}, ${fp.files} files`);
} else if (cmd === 'check') {
  const m = JSON.parse(readFileSync(MANIFEST, 'utf8'));
  if (m.repo !== REPO || !/^[0-9a-f]{40}$/.test(m.commit ?? '')) fail(`${MANIFEST}: repo must be ${REPO} and commit a 40-hex sha`);
  if (JSON.stringify(m.paths) !== JSON.stringify(PATHS)) {
    fail(`${MANIFEST} lists different paths from scripts/vendor-marketplaces.mjs PATHS. Change PATHS (a reviewed edit), then sync.`);
  }
  const fp = fingerprint(PATHS);
  if (fp.sha256 !== m.sha256 || fp.files !== m.files) {
    console.error(`The vendored marketplace layer differs from ${m.repo}@${m.commit.slice(0, 7)} (${fp.files} files here, ${m.files} pinned).`);
    console.error(`It is vendored: change it in ${m.repo}, then run scripts/sync-marketplaces.sh <sha>. Don't edit it here.`);
    process.exit(1);
  }
  console.log(`vendored marketplace layer matches ${m.repo}@${m.commit.slice(0, 7)} (${fp.files} files)`);
} else {
  console.error('usage: node scripts/vendor-marketplaces.mjs check | paths | stamp --commit <sha>');
  process.exit(2);
}
