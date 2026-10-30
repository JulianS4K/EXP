import { describe, it, expect } from 'vitest';
import {
  slugProblem, suggestSlug, apName, fediverseHandles, consentText, joinAction, friendlyError, inviteToken,
  earlyAccessUntil, eventBadge, placeLine, memberCountLabel, eventIdFromLink,
} from './communities';

describe('communities helpers', () => {
  it('validates link names like the SQL check', () => {
    expect(slugProblem('bar-run-club')).toBeNull();
    expect(slugProblem('inner_room')).toBeNull();
    expect(slugProblem('ab')).toMatch(/3 to 40/);
    expect(slugProblem('x'.repeat(41))).toMatch(/3 to 40/);
    expect(slugProblem('-bad')).toMatch(/Letters/);
    expect(slugProblem('bad_')).toMatch(/Letters/);
    expect(slugProblem('has space')).toMatch(/Letters/);
    expect(slugProblem('org_bar')).toMatch(/reserved/);
    expect(slugProblem('admin')).toMatch(/reserved/);
  });

  it('suggests a valid slug from a name', () => {
    expect(suggestSlug('Bar Run Club!')).toBe('bar-run-club');
    expect(suggestSlug('Café Société')).toBe('cafe-societe');
    expect(slugProblem(suggestSlug('A'))).toBeNull();
    expect(slugProblem(suggestSlug('x'.repeat(80)))).toBeNull();
  });

  it('derives the fediverse names', () => {
    expect(apName('bar-run-club')).toBe('bar_run_club');
    expect(fediverseHandles('bar-run-club', 'https://exos.app/bridge')).toEqual({ mastodon: '@bar_run_club@exos.app', lemmy: '!bar_run_club@exos.app' });
  });

  it('writes consent text that names the channels and how to stop', () => {
    expect(consentText('Run Club', true, false)).toMatch(/^Send me email updates from Run Club/);
    const both = consentText('Run Club', true, true);
    expect(both).toContain('email and text');
    expect(both).toContain('reply STOP');
    expect(both.length).toBeGreaterThanOrEqual(20);
    expect(both.length).toBeLessThanOrEqual(600);
  });

  it('picks the join button state', () => {
    expect(joinAction('open', undefined, true, false).kind).toBe('join');
    expect(joinAction('approval', undefined, true, false).kind).toBe('request');
    expect(joinAction('invite', undefined, true, false).kind).toBe('invite_only');
    expect(joinAction('invite', undefined, true, true).kind).toBe('join');
    expect(joinAction('open', undefined, false, false).kind).toBe('sign_in');
    expect(joinAction('open', 'active', true, false).kind).toBe('member');
    expect(joinAction('open', 'pending', true, false).kind).toBe('pending');
    expect(joinAction('open', 'banned', true, true).kind).toBe('banned');
    expect(joinAction('approval', 'left', true, false).kind).toBe('request');
  });

  it('cleans RPC errors', () => {
    expect(friendlyError(new Error('exos_community_join: this community is invite only'))).toBe('This community is invite only.');
    expect(friendlyError({ message: 'exos_community_post: at most 10 posts a day' })).toBe('At most 10 posts a day.');
    expect(friendlyError('')).toBe('Something went wrong. Try again.');
  });

  it('reads invite tokens from the link only in the right shape', () => {
    const t = 'a'.repeat(64);
    expect(inviteToken(`?invite=ecv_${t}`)).toEqual({ kind: 'member', token: `ecv_${t}` });
    expect(inviteToken(`?host=ech_${t}`)).toEqual({ kind: 'host', token: `ech_${t}` });
    expect(inviteToken(`?invite=ech_${t}`)).toBeNull();
    expect(inviteToken('?invite=<script>')).toBeNull();
    expect(inviteToken('')).toBeNull();
  });

  it('badges members-only and early access', () => {
    const now = new Date('2026-10-30T12:00:00Z');
    const base = { id: 'x', name: 'E', slug: null, starts_at: null, timezone: null, venue_name: null, image_url: null };
    expect(eventBadge({ ...base, members_only: true }, now)).toBe('Members only');
    expect(eventBadge({ ...base, early_access_until: '2026-10-31T00:00:00Z' }, now)).toBe('Member early access');
    expect(eventBadge({ ...base, early_access_until: '2026-10-29T00:00:00Z' }, now)).toBeNull();
    expect(earlyAccessUntil({ early_access_until: 'garbage' }, now)).toBeNull();
  });

  it('formats place and member count', () => {
    expect(placeLine({ city: 'Brooklyn', region: 'NY', country: 'US' })).toBe('Brooklyn, NY');
    expect(placeLine({ city: null, region: null, country: 'US' })).toBe('US');
    expect(memberCountLabel(1)).toBe('1 member');
    expect(memberCountLabel(1200)).toBe('1,200 members');
  });

  it('reads an event id from a pasted link', () => {
    const id = '11111111-1111-4111-8111-111111111111';
    expect(eventIdFromLink(`https://exos.app/bridge/event/${id}?ref=x`)).toBe(id);
    expect(eventIdFromLink(id.toUpperCase())).toBe(id);
    expect(eventIdFromLink('https://exos.app/bridge/e/some-slug')).toBeNull();
    expect(eventIdFromLink(`${id}x`)).toBeNull();
  });
});
