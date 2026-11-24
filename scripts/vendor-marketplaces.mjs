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
//   node scripts/vendor-marketplaces.mjs extract --git-dir <dir> --commit <sha> --out <dir>
//       Writes one upstream commit's vendored files from git blobs (sync).
//   node scripts/vendor-marketplaces.mjs stamp --commit <sha>
//       Used by scripts/sync-marketplaces.sh after copying a new commit in.
//
// The check proves the files match the manifest, not that the manifest
// matches upstream: someone could edit a file and re-stamp. Review catches
// that; a re-stamp without a sync shows up as a manifest change with no
// matching upstream commit.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
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
// src/lib/marketplace/ also holds Exos-owned files (resale gate, channel
// splits), so only entries strictly below it may be vendored.
const MIXED = 'src/lib/marketplace/';

function fail(msg) {
  console.error(msg);
  process.exit(1);
}
// Every path is plain ASCII segments (letters, digits, '.', '_', '-'; no
// segment starts with '.'), sits under one of PREFIXES (strictly below MIXED)
// and is unique.
const SEGMENTED = /^[A-Za-z0-9_-][A-Za-z0-9._-]*(\/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\/?$/;
if (new Set(PATHS).size !== PATHS.length) fail('vendor-marketplaces: PATHS has a duplicate');
for (const p of PATHS) {
  if (!SEGMENTED.test(p) || p.split('/').includes('..') || !PREFIXES.some((x) => p.startsWith(x) && (p.length > x.length || x !== MIXED))) {
    fail(`vendor-marketplaces: bad path ${JSON.stringify(p)}`);
  }
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
    if (st.mode & 0o111) fail(`vendor-marketplaces: ${q} is executable; vendored files must not be`);
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
} else if (cmd === 'extract') {
  // Write the vendored files of one upstream commit into --out, straight
  // from git's blobs: no checkout, so no symlinks, no .gitattributes
  // filters or eol rewriting, and the bytes are exactly the commit's.
  // Refuses, before writing anything, any entry at, inside or above a
  // vendored path that is not a plain 100644 file or a tree (symlink
  // 120000, executable 100755, submodule 160000), any dot-named entry, and
  // a vendored path missing from the commit.
  const gitDir = arg('--git-dir'); const commit = arg('--commit'); const out = arg('--out');
  if (!gitDir || !/^[0-9a-f]{40}$/.test(commit ?? '') || !out) {
    console.error('usage: extract --git-dir <dir> --commit <40-hex sha> --out <dir>');
    process.exit(2);
  }
  const git = (...a) => execFileSync('git', ['--git-dir', gitDir, ...a], { maxBuffer: 1 << 30 });
  const roots = PATHS.map((p) => p.replace(/\/$/, ''));
  const near = (f) => roots.some((p) => f === p || f.startsWith(p + '/') || p.startsWith(f + '/'));
  const inside = (f) => PATHS.some((p) => (p.endsWith('/') ? f.startsWith(p) : f === p));
  const entries = git('ls-tree', '-r', '-t', '-z', '--full-tree', commit).toString('utf8').split('\0').filter(Boolean)
    .map((e) => { const m = /^(\d{6}) (\w+) ([0-9a-f]{40})\t([\s\S]*)$/.exec(e); if (!m) fail(`extract: unreadable tree entry ${JSON.stringify(e)}`); return { mode: m[1], type: m[2], oid: m[3], path: m[4] }; })
    .filter((e) => near(e.path));
  const bad = entries.filter((e) => !((e.mode === '100644' && e.type === 'blob') || (e.mode === '040000' && e.type === 'tree'))
    || e.path.split('/').some((s) => s.startsWith('.')));
  if (bad.length) fail(`extract: refusing ${commit}, it holds a symlink, executable, submodule or dot entry at or above a vendored path:\n` + bad.slice(0, 5).map((e) => `  ${e.mode} ${JSON.stringify(e.path)}`).join('\n'));
  const files = entries.filter((e) => e.type === 'blob' && inside(e.path));
  for (const p of PATHS) {
    const ok = p.endsWith('/') ? entries.some((e) => e.type === 'tree' && e.path === p.slice(0, -1)) : files.some((e) => e.path === p);
    if (!ok) fail(`extract: ${commit} has no ${p}`);
  }
  for (const e of files) {
    if (!SEGMENTED.test(e.path)) fail(`extract: refusing file name ${JSON.stringify(e.path)}`);
    const dest = posix.join(out, e.path);
    mkdirSync(posix.dirname(dest), { recursive: true });
    writeFileSync(dest, git('cat-file', 'blob', e.oid), { mode: 0o644 });
  }
  console.log(`extracted ${files.length} files from ${commit.slice(0, 7)}`);
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
  console.error('usage: node scripts/vendor-marketplaces.mjs check | paths | stamp --commit <sha> | extract --git-dir <dir> --commit <sha> --out <dir>');
  process.exit(2);
}
