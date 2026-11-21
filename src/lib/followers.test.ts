import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import {
  FOLLOWERS_CSV_HEADER, followersCsvRows, noticeLine, parseNotice, parseOrgFollowers, unfollowToken,
} from './followers';
import { toCsv } from './csv';

describe('the event editor line', () => {
  it('before publishing: how many will be notified, or why none', () => {
    expect(noticeLine(parseNotice({ state: 'before', followers: 5, eligible: true, reason: null, will_notify: 3 })))
      .toBe('3 followers will be notified when you publish.');
    expect(noticeLine(parseNotice({ state: 'before', followers: 5, eligible: true, reason: null, will_notify: 1 })))
      .toBe('1 follower will be notified when you publish.');
    expect(noticeLine(parseNotice({ state: 'before', followers: 2, eligible: false, reason: 'hidden', will_notify: 0 })))
      .toBe("Followers won't be emailed: the event is hidden from search and listings.");
    expect(noticeLine(parseNotice({ state: 'before', followers: 2, eligible: true, reason: null, will_notify: 0 })))
      .toBe('None of your 2 followers can be emailed right now.');
  });
  it('after: notified, and the ones waiting for their daily window', () => {
    expect(noticeLine(parseNotice({ state: 'after', followers: 9, eligible: true, notified: 4, waiting: 0, not_notified: 5 })))
      .toBe('Notified 4 followers.');
    expect(noticeLine(parseNotice({ state: 'after', followers: 9, eligible: true, notified: 1, waiting: 2, not_notified: 0 })))
      .toBe('Notified 1 follower, 2 more waiting (one email a day per follower).');
  });
  it('says nothing when the org has no followers or the answer is malformed', () => {
    expect(noticeLine(parseNotice({ state: 'before', followers: 0, eligible: true, will_notify: 0 }))).toBeNull();
    expect(noticeLine(parseNotice({ state: 'weird' }))).toBeNull();
    expect(parseNotice(null)).toBeNull();
    expect(parseNotice({ state: 'before', followers: 1, reason: 'sneaky', will_notify: '2' })).toEqual({
      state: 'before', followers: 1, eligible: false, reason: null, willNotify: 2,
    });
  });
});

describe('the follower list', () => {
  const data = {
    total: 5, listed: 2, not_listed: 3, gets_new_event_mail: 1,
    rows: [
      { fan_id: 'f1', email: 'a@x.com', first_name: 'Ann', last_name: null, followed_at: '2026-11-01T00:00:00Z', email_list: 'subscribed', gets_new_event_mail: true },
      { fan_id: 'f3', email: 'c@x.com', email_list: 'unsubscribed', gets_new_event_mail: false },
      { fan_id: 'x' },
    ],
  };
  it('parses counts and rows', () => {
    const r = parseOrgFollowers(data);
    expect(r).toMatchObject({ total: 5, listed: 2, notListed: 3, getsNewEventMail: 1 });
    expect(r.rows.map((x) => x.email)).toEqual(['a@x.com', 'c@x.com']);
    expect(r.rows[0].followedAt?.toISOString()).toBe('2026-11-01T00:00:00.000Z');
    expect(r.rows[1].emailList).toBe('unsubscribed');
    expect(parseOrgFollowers(null)).toEqual({ total: 0, listed: 0, notListed: 0, getsNewEventMail: 0, rows: [] });
  });
  it('CSV: one row per follower, formulas defused', () => {
    const rows = followersCsvRows([{ ...data.rows[0], first_name: '=HYPERLINK("x")' }, data.rows[1]]);
    expect(rows[0]).toEqual(['a@x.com', '=HYPERLINK("x")', '', '2026-11-01T00:00:00Z', 'subscribed', 'yes']);
    expect(rows[1][5]).toBe('no');
    const csv = toCsv(FOLLOWERS_CSV_HEADER, rows);
    expect(csv.split('\n')[0]).toContain('email,first_name,last_name,followed_at,email_list,gets_new_event_email');
    expect(csv).not.toMatch(/,=HYPERLINK/);
  });
});

describe('unfollow links', () => {
  it('accepts only a 64-hex token', () => {
    expect(unfollowToken('A'.repeat(64))).toBe('a'.repeat(64));
    expect(unfollowToken('a'.repeat(63))).toBeNull();
    expect(unfollowToken('"><x')).toBeNull();
    expect(unfollowToken(null)).toBeNull();
  });
});
