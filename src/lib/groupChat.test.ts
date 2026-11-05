import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import {
  closesLabel, formatPhone, instagramUrl, linkify, mergeMessages, messageProblem, parseContacts, parseMessage, parseState,
  type GroupMessage,
} from './groupChat';

const m = (id: string, at: string): GroupMessage => ({
  id, groupId: 'g', senderId: 'u', senderName: 'A', body: id, source: 'app', createdAt: new Date(at),
});

describe('messageProblem', () => {
  it('mirrors the server caps', () => {
    expect(messageProblem('  ')).toBe('Type a message.');
    expect(messageProblem('x'.repeat(1000))).toBeNull();
    expect(messageProblem('x'.repeat(1001))).toMatch(/1,000/);
    expect(messageProblem('a http://a.b b https://c.d www.e.f')).toBeNull();
    expect(messageProblem('a http://a.b b https://c.d www.e.f http://g.h')).toMatch(/3 links/);
  });
});

describe('linkify', () => {
  it('only http(s) and www links, punctuation kept as text', () => {
    expect(linkify('see https://exos.events/e/1. ok')).toEqual([
      { text: 'see ' }, { text: 'https://exos.events/e/1', href: 'https://exos.events/e/1' }, { text: '. ok' },
    ]);
    expect(linkify('www.example.com!')).toEqual([{ text: 'www.example.com', href: 'https://www.example.com' }, { text: '!' }]);
    expect(linkify('javascript:alert(1)')).toEqual([{ text: 'javascript:alert(1)' }]);
    expect(linkify('no links')).toEqual([{ text: 'no links' }]);
    expect(linkify('')).toEqual([{ text: '' }]);
  });
});

describe('mergeMessages', () => {
  it('dedupes by id and sorts oldest first', () => {
    const a = [m('2', '2026-10-30T10:02:00Z'), m('1', '2026-10-30T10:01:00Z')];
    const b = [m('2', '2026-10-30T10:02:00Z'), m('3', '2026-10-30T10:03:00Z')];
    expect(mergeMessages(a, b).map((x) => x.id)).toEqual(['1', '2', '3']);
  });
});

describe('parsing', () => {
  it('reads a realtime row', () => {
    expect(parseMessage({ id: '1', group_id: 'g', sender_name: 'Mo', body: 'hi', source: 'sms', created_at: '2026-10-30T10:00:00Z' }))
      .toMatchObject({ id: '1', source: 'sms', senderId: null, senderName: 'Mo' });
    expect(parseMessage({ id: '1' })).toBeNull();
    expect(parseMessage({ id: '1', group_id: 'g', source: 'weird', created_at: 'x' })?.source).toBe('app');
  });
  it('reads the group state', () => {
    const s = parseState({
      id: 'g', org_id: 'o', title: 'Table 4', open: true, closes_at: '2026-11-07T00:00:00Z', relay_enabled: true,
      me: { user_id: 'u', display_name: 'Mo', relay_number: '+13325550001', sms_on: true, sms_phone_hint: '…0101' },
      members: [{ user_id: 'u', display_name: 'Mo', me: true }, { user_id: 'v', display_name: 'Ana', blocked: true }],
    });
    expect(s.me.relayNumber).toBe('+13325550001');
    expect(s.members[1]).toMatchObject({ displayName: 'Ana', blocked: true, me: false });
    expect(s.closesAt?.toISOString()).toBe('2026-11-07T00:00:00.000Z');
  });
  it('reads contacts', () => {
    const c = parseContacts({ event_over: true, mine: [{ kind: 'phone', to_user: null, value: '+1' }],
      revealed: [{ user_id: 'v', display_name: 'Ana', kind: 'instagram', value: 'ana.b' }] });
    expect(c.mine[0]).toMatchObject({ kind: 'phone', toUser: null });
    expect(c.revealed[0].kind).toBe('instagram');
  });
});

describe('labels', () => {
  const now = new Date('2026-10-30T12:00:00Z');
  it('closes label', () => {
    expect(closesLabel(null, now)).toBeNull();
    expect(closesLabel(new Date('2026-10-30T11:00:00Z'), now)).toBe('Chat closed');
    expect(closesLabel(new Date('2026-10-30T20:00:00Z'), now)).toBe('Chat closes today');
    expect(closesLabel(new Date('2026-10-31T13:00:00Z'), now)).toBe('Chat closes in 1 day');
    expect(closesLabel(new Date('2026-11-03T13:00:00Z'), now)).toBe('Chat closes in 4 days');
  });
  it('phones and handles', () => {
    expect(formatPhone('+13325550001')).toBe('+1 (332) 555-0001');
    expect(formatPhone('+447700900123')).toBe('+447700900123');
    expect(instagramUrl('@ana.b')).toBe('https://www.instagram.com/ana.b/');
  });
});
