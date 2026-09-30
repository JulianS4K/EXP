import { describe, expect, it } from 'vitest';
import { audienceCsv, audienceFilename, catalogFeedLinks, parseAudienceExport, type AudienceRow } from './audienceCsv';

const H = (c: string) => c.repeat(64);
const rows: AudienceRow[] = [
  { email_sha256: H('a'), phone_sha256: H('b'), phone_digits_sha256: H('c') },
  { email_sha256: H('d'), phone_sha256: null, phone_digits_sha256: null },
];

describe('audienceCsv', () => {
  it('Meta: email,phone with the digits-only phone hash', () => {
    expect(audienceCsv(rows, 'meta')).toBe(`email,phone\r\n${H('a')},${H('c')}\r\n${H('d')},\r\n`);
  });

  it('Google: Email,Phone with the E.164 phone hash', () => {
    expect(audienceCsv(rows, 'google')).toBe(`Email,Phone\r\n${H('a')},${H('b')}\r\n${H('d')},\r\n`);
  });

  it('TikTok: email_sha256,phone_sha256', () => {
    expect(audienceCsv(rows, 'tiktok').split('\r\n')[0]).toBe('email_sha256,phone_sha256');
  });

  it('never writes anything that is not a hash', () => {
    const csv = audienceCsv([
      { email_sha256: 'someone@example.com', phone_sha256: null, phone_digits_sha256: null },
      { email_sha256: H('e'), phone_sha256: '+15551234567', phone_digits_sha256: '=HYPERLINK("x")' },
    ], 'meta');
    expect(csv).toBe(`email,phone\r\n${H('e')},\r\n`);
    expect(csv).not.toContain('@');
  });

  it('writes just the header for an empty list', () => {
    expect(audienceCsv([], 'google')).toBe('Email,Phone\r\n');
  });
});

describe('parseAudienceExport', () => {
  it('keeps hashes and drops malformed phone hashes', () => {
    const out = parseAudienceExport({ count: 1, generated_at: '2026-09-30T00:00:00Z', rows: [{ email_sha256: H('a'), phone_sha256: 'x', phone_digits_sha256: H('c') }] });
    expect(out).toEqual({ count: 1, generated_at: '2026-09-30T00:00:00Z', rows: [{ email_sha256: H('a'), phone_sha256: null, phone_digits_sha256: H('c') }] });
  });

  it('refuses a response with a raw email or no rows', () => {
    expect(() => parseAudienceExport({ rows: [{ email_sha256: 'a@b.co' }] })).toThrow();
    expect(() => parseAudienceExport(null)).toThrow();
  });
});

describe('audienceFilename', () => {
  it('names the file by org, event, platform and date', () => {
    const d = new Date('2026-09-30T12:00:00Z');
    expect(audienceFilename('blue-room', 'meta', d)).toBe('blue-room-meta-audience-2026-09-30.csv');
    expect(audienceFilename('Blue Room!', 'tiktok', d, 'Late Night')).toBe('blue-room-late-night-tiktok-audience-2026-09-30.csv');
  });
});

describe('catalogFeedLinks', () => {
  it('builds one feed URL per platform', () => {
    const links = catalogFeedLinks('https://p.supabase.co/functions/v1/', 'blue-room');
    expect(links.map((l) => l.url)).toEqual([
      'https://p.supabase.co/functions/v1/exos-catalog-feed/blue-room.csv?format=meta',
      'https://p.supabase.co/functions/v1/exos-catalog-feed/blue-room.csv?format=tiktok',
      'https://p.supabase.co/functions/v1/exos-catalog-feed/blue-room.xml?format=google',
    ]);
  });

  it('is empty without a base or with a bad slug', () => {
    expect(catalogFeedLinks('', 'blue-room')).toEqual([]);
    expect(catalogFeedLinks('https://p.supabase.co/functions/v1', 'Bad Slug')).toEqual([]);
  });
});
