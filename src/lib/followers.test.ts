import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import {
  followerName, FOLLOWERS_CSV_HEADER, followersCsvRows, noticeLine, parseNotice, parseOrgFollowers, unfollowToken,
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
  it('after: notified, and the ones waiting for the batched send', () => {
    expect(noticeLine(parseNotice({ state: 'after', followers: 9, eligible: true, notified: 4, waiting: 0, not_notified: 5 })))
      .toBe('Notified 4 followers.');
    expect(noticeLine(parseNotice({ state: 'after', followers: 9, eligible: true, notified: 1, waiting: 2, not_notified: 0 })))
      .toBe('Notified 1 follower, 2 more waiting (sent in batches, at most one email a day per follower).');
  });
  it('right after publishing: everyone is still waiting (the publish only records them)', () => {
    expect(noticeLine(parseNotice({ state: 'after', followers: 9, eligible: true, notified: 0, waiting: 3, not_notified: 6 })))
      .toBe('3 followers waiting for the new-event email (sent in batches, at most one email a day per follower).');
    expect(noticeLine(parseNotice({ state: 'after', followers: 9, eligible: true, notified: 0, waiting: 1, not_notified: 0 })))
      .toBe('1 follower waiting for the new-event email (sent in batches, at most one email a day per follower).');
    expect(noticeLine(parseNotice({ state: 'after', followers: 9, eligible: true, notified: 0, waiting: 0, not_notified: 9 })))
      .toBe('Notified 0 followers.');
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
  // exos_org_followers (mig 20261112100000): names and fan status, no address.
  const data = {
    total: 5, listed: 2, not_listed: 3, gets_new_event_mail: 1,
    rows: [
      { fan_id: 'f1', first_name: 'Ann', last_name: null, followed_at: '2026-11-01T00:00:00Z', email_list: 'subscribed', gets_new_event_mail: true },
      { fan_id: 'f3', email_list: 'unsubscribed', gets_new_event_mail: false },
      { first_name: 'No id' },
    ],
  };
  // exos_org_followers_export: the same rows with the address.
  const exported = [
    { email: 'a@x.com', first_name: 'Ann', last_name: null, followed_at: '2026-11-01T00:00:00Z', email_list: 'subscribed', gets_new_event_mail: true },
    { email: 'c@x.com', email_list: 'unsubscribed', gets_new_event_mail: false },
  ];
  it('parses counts and rows, keyed by fan id, with no address', () => {
    const r = parseOrgFollowers(data);
    expect(r).toMatchObject({ total: 5, listed: 2, notListed: 3, getsNewEventMail: 1 });
    expect(r.rows.map((x) => x.fanId)).toEqual(['f1', 'f3']);
    expect(r.rows[0].followedAt?.toISOString()).toBe('2026-11-01T00:00:00.000Z');
    expect(r.rows[1].emailList).toBe('unsubscribed');
    expect(r.rows.every((x) => !('email' in x))).toBe(true);
    // An address the server might still send is never kept.
    const leaky = parseOrgFollowers({ ...data, rows: [{ ...data.rows[0], email: 'a@x.com' }] });
    expect(JSON.stringify(leaky)).not.toContain('a@x.com');
    expect(parseOrgFollowers(null)).toEqual({ total: 0, listed: 0, notListed: 0, getsNewEventMail: 0, rows: [] });
  });
  it('names: first and last, or none', () => {
    const [ann, nameless] = parseOrgFollowers(data).rows;
    expect(followerName(ann)).toBe('Ann');
    expect(followerName(nameless)).toBeNull();
    expect(followerName({ firstName: 'Una', lastName: 'One' })).toBe('Una One');
  });
  it('CSV: one row per follower, formulas defused', () => {
    const rows = followersCsvRows([{ ...exported[0], first_name: '=HYPERLINK("x")' }, exported[1]]);
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
