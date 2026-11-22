#!/usr/bin/env node
// The resale marketplace layer is vendored from JulianS4K/exos-marketplaces
// (the source of truth) at the same paths. vendor/exos-marketplaces.json pins
// the upstream commit, the vendored paths and a fingerprint of every vendored
// file.
//
//   node scripts/vendor-marketplaces.mjs check
//       CI: the vendored files are exactly the pinned ones (no local edits,
//       nothing added or removed). Change them upstream, then sync.
//   node scripts/vendor-marketplaces.mjs stamp --commit <sha> --paths <file>
//       Used by scripts/sync-marketplaces.sh after copying a new commit in.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const MANIFEST = 'vendor/exos-marketplaces.json';
const REPO = 'JulianS4K/exos-marketplaces';

const walk = (d) => readdirSync(d).sort().flatMap((f) => {
  const p = join(d, f);
  return statSync(p).isDirectory() ? walk(p) : [p];
});
const filesOf = (paths) => paths.flatMap((p) => {
  if (p.endsWith('/')) return existsSync(p) ? walk(p.slice(0, -1)) : [];
  return existsSync(p) ? [p] : [];
}).sort();
const sha = (b) => createHash('sha256').update(b).digest('hex');
function fingerprint(paths) {
  const files = filesOf(paths);
  const lines = files.map((f) => `${f}\0${sha(readFileSync(f))}`);
  return { files: files.length, sha256: sha(lines.join('\n')), lines };
}
const readPaths = (file) => readFileSync(file, 'utf8').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));

const [cmd, ...args] = process.argv.slice(2);
const arg = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };

if (cmd === 'stamp') {
  const commit = arg('--commit');
  const pathsFile = arg('--paths');
  if (!/^[0-9a-f]{40}$/.test(commit ?? '') || !pathsFile) {
    console.error('usage: stamp --commit <40-hex sha> --paths <sync-paths.txt>');
    process.exit(2);
  }
  const paths = readPaths(pathsFile);
  const fp = fingerprint(paths);
  writeFileSync(MANIFEST, JSON.stringify({ repo: REPO, commit, paths, files: fp.files, sha256: fp.sha256 }, null, 2) + '\n');
  console.log(`stamped ${MANIFEST}: ${REPO}@${commit.slice(0, 7)}, ${fp.files} files`);
} else if (cmd === 'check') {
  const m = JSON.parse(readFileSync(MANIFEST, 'utf8'));
  const fp = fingerprint(m.paths);
  if (fp.sha256 !== m.sha256 || fp.files !== m.files) {
    console.error(`The vendored marketplace layer differs from ${m.repo}@${m.commit.slice(0, 7)} (${fp.files} files here, ${m.files} pinned).`);
    console.error(`It is vendored: change it in ${m.repo}, then run scripts/sync-marketplaces.sh <commit>. Don't edit it here.`);
    process.exit(1);
  }
  console.log(`vendored marketplace layer matches ${m.repo}@${m.commit.slice(0, 7)} (${fp.files} files)`);
} else {
  console.error('usage: node scripts/vendor-marketplaces.mjs check | stamp --commit <sha> --paths <file>');
  process.exit(2);
}
