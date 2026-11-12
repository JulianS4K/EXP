// Static guard (mig 20261113130000, docs/discord.md): only
// _shared/channels/discord.ts talks to Discord, and its install exchange
// calls the token endpoint and nothing else.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const FUNCTIONS = resolve(__dirname, '../../supabase/functions');
const DISCORD_TS = '_shared/channels/discord.ts';

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

describe('Discord hosts', () => {
  it('no edge function file but discord.ts names discord.com or discordapp.com', () => {
    const files = walk(FUNCTIONS).filter((f) => /\.(ts|js|json)$/.test(f) && !/_test\.ts$/.test(f));
    const hits = files.map((f) => relative(FUNCTIONS, f))
      .filter((f) => f !== DISCORD_TS && /discord(app)?\.com/i.test(readFileSync(join(FUNCTIONS, f), 'utf8')));
    expect(hits).toEqual([]);
  });

  it('discord.ts has one base host, and the install exchange calls only the token endpoint', () => {
    const src = readFileSync(join(FUNCTIONS, DISCORD_TS), 'utf8');
    const hosts = new Set([...src.matchAll(/https:\/\/([a-z0-9.-]*discord(?:app)?\.com)/gi)].map((m) => m[1].toLowerCase()));
    expect([...hosts]).toEqual(['discord.com']);
    const body = src.slice(src.indexOf('export async function exchangeInstallCode'), src.indexOf('export function webhookUrlParts'));
    const calls = [...body.matchAll(/fetchFn\(([^,]+),/g)].map((m) => m[1].trim());
    expect(calls).toEqual(['DISCORD_TOKEN_URL']);
    expect(src).toContain('export const DISCORD_TOKEN_URL = `${DISCORD_API}/oauth2/token`;');
    // Two fetches in the module: that one, and the io's, to DISCORD_API + an allow-listed path.
    expect([...src.matchAll(/\bfetch(?:Fn)?\(/g)].length).toBe(2);
    expect(src).toContain('await opts.fetch(DISCORD_API + path,');
  });
});
