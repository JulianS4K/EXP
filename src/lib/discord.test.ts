import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import {
  isDiscordAuthorizeUrl, parseDiscordEventStatus, parseDiscordStatus, postLine, rpcMessage, syncLine, WEBHOOK_URL_RE, webhookUrlOk,
} from './discord';
import { webhookUrlParts } from '../../supabase/functions/_shared/channels/discord.ts';
import { confirmPrompt, readOAuthReturn, refusalMessage, stripOAuthHash, stripOAuthReturn } from './oauthReturn';

const HOOK = '223456789012345679';
const TOKEN = 'T3' + 'aB9_-x'.repeat(11) + 'Zq';

describe('webhook URL check', () => {
  const good = [
    `https://discord.com/api/webhooks/${HOOK}/${TOKEN}`,
    `https://discordapp.com/api/webhooks/${HOOK}/${TOKEN}`,
    `https://discord.com/api/v10/webhooks/${HOOK}/${TOKEN}/`,
  ];
  const bad = [
    `http://discord.com/api/webhooks/${HOOK}/${TOKEN}`,
    `https://ptb.discord.com/api/webhooks/${HOOK}/${TOKEN}`,
    `https://discord.com.evil.example/api/webhooks/${HOOK}/${TOKEN}`,
    `https://discord.com:443/api/webhooks/${HOOK}/${TOKEN}`,
    `https://discord.com/api/webhooks/${HOOK}/${TOKEN}?wait=true`,
    `https://discord.com/api/webhooks/${HOOK}/short`,
    `https://discord.com/api/channels/${HOOK}/messages`,
  ];
  it('takes Discord channel webhooks only', () => {
    for (const u of good) expect(webhookUrlOk(u), u).toBe(true);
    for (const u of bad) expect(webhookUrlOk(u), u).toBe(false);
  });
  it('is the same rule as the edge function and the SQL', () => {
    for (const u of [...good, ...bad]) expect(webhookUrlParts(u) !== null, u).toBe(webhookUrlOk(u));
    const sql = readFileSync(resolve(__dirname, '../../supabase/migrations/20261113130000_exos_discord.sql'), 'utf8');
    // The SQL pattern is the same regex, without JS's escaped '/'.
    expect(sql).toContain(`'${WEBHOOK_URL_RE.source.replace(/\\\//g, '/')}'`);
  });
});

describe('the bot install link', () => {
  it('only discord.com/oauth2/authorize with scope bot', () => {
    expect(isDiscordAuthorizeUrl('https://discord.com/oauth2/authorize?client_id=1&scope=bot&permissions=17592186044416')).toBe(true);
    expect(isDiscordAuthorizeUrl('https://discord.com/oauth2/authorize?scope=identify')).toBe(false);
    expect(isDiscordAuthorizeUrl('https://evil.example/oauth2/authorize?scope=bot')).toBe(false);
    expect(isDiscordAuthorizeUrl('javascript:alert(1)')).toBe(false);
    expect(isDiscordAuthorizeUrl(null)).toBe(false);
  });
  it('comes back through the confirm screen', () => {
    const S = 'S'.repeat(43);
    const T = 'T'.repeat(43);
    expect(readOAuthReturn(`?discord=finish&discord_state=${S}`, `#discord_finish=${T}`))
      .toEqual({ provider: 'discord', kind: 'finish', state: S, finish: T });
    expect(readOAuthReturn('?discord=error&reason=denied', '')).toEqual({ provider: 'discord', kind: 'error', reason: 'denied' });
    expect(stripOAuthReturn(`?discord=finish&discord_state=${S}&tab=x`)).toBe('?tab=x');
    expect(stripOAuthHash(`#discord_finish=${T}`)).toBe('');
    expect(confirmPrompt('discord', 'Blue Room')).toBe('Link the Discord server you just added the Exos bot to with Blue Room?');
    expect(refusalMessage('discord', 'taken')).toMatch(/another Exos organization/);
    expect(refusalMessage('discord', 'other_user')).toMatch(/nothing was connected/);
  });
});

describe('status', () => {
  it('reads the org status, never more than a hint', () => {
    const s = parseDiscordStatus({ can_manage: true, is_owner: false, webhook: { set: true, hint: '…5679', set_at: '2026-11-12T10:00:00Z' },
      guild: { linked: true, id: '423456789012345671', name: 'Blue Room' }, writes_enabled: false, auto_post: true, shown_events: 2 });
    expect(s).toEqual({ canManage: true, isOwner: false, webhook: { set: true, hint: '…5679', setAt: '2026-11-12T10:00:00Z' },
      guild: { linked: true, name: 'Blue Room' }, writesEnabled: false, autoPost: true, shownEvents: 2 });
    expect(parseDiscordStatus(null).webhook.set).toBe(false);
  });
  it('says what each post and the scheduled event are doing', () => {
    const e = parseDiscordEventStatus({ can_manage: true, event_status: 'published', has_webhook: true, guild_linked: true, guild_name: 'Blue Room',
      show: true, sync: { status: 'synced', on_discord: true, pending: false }, posts: [{ kind: 'publish', status: 'dry_run' }, { kind: 'x' }] });
    expect(e.posts).toHaveLength(1);
    expect(postLine(e.posts[0])).toMatch(/^Dry run/);
    expect(postLine(undefined)).toBe('Not posted yet.');
    expect(postLine({ kind: 'reminder', status: 'error', sentAt: null, lastError: 'the webhook was deleted' })).toBe('Not posted: the webhook was deleted.');
    expect(syncLine(e)).toBe("On Blue Room's events list.");
    expect(syncLine({ ...e, guildLinked: false })).toMatch(/Add the Exos bot/);
    expect(syncLine({ ...e, show: false })).toBe('Not on Discord.');
    expect(syncLine({ ...e, sync: { ...e.sync!, status: 'dry_run' } })).toMatch(/^Dry run/);
  });
  it('shows the SQL refusal without the function name', () => {
    expect(rpcMessage({ message: 'exos_discord_request_post: only a published event that isn\'t over can be posted' }))
      .toBe('only a published event that isn\'t over can be posted');
    expect(rpcMessage(null)).toBe('Something went wrong.');
  });
});
