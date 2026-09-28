import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  _resetErrorReportingForTests,
  configureErrorReporting,
  installGlobalErrorHandlers,
  reportError,
  scrub,
  scrubError,
  stripQuery,
} from './errorReporting';
import { parseSentryDsn, sentryStoreUrl } from '../../supabase/functions/_shared/scrub.ts';
import { redactError, reportError as reportEdgeError, secretValues } from '../../supabase/functions/_shared/log.ts';

const DSN = 'https://abc123publickey@o42.ingest.us.sentry.io/4507';

afterEach(() => {
  _resetErrorReportingForTests();
  vi.restoreAllMocks();
});

describe('scrub', () => {
  it('removes emails', () => {
    expect(scrub('no ticket for jane.doe+vip@example.com')).toBe('no ticket for [email]');
  });

  it('strips every query string and fragment from URLs', () => {
    expect(scrub('GET https://h.test/bridge/claim/abc?k=SECRETKEY#x failed')).toBe('GET https://h.test/bridge/claim/abc?[redacted] failed');
    expect(stripQuery('https://h.test/a/b?source=key123&x=1')).toBe('https://h.test/a/b');
  });

  it('removes credentials, JWTs, prefixed keys and long tokens', () => {
    const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
    const out = scrub(`Authorization: Bearer abcdef0123456789xyz; jwt ${jwt}; sk_live_51Habcdefghij; token=zzz999; ` +
      'id a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8');
    expect(out).not.toMatch(/abcdef0123456789xyz|eyJhbGci|sk_live_51H|zzz999|a1b2c3d4e5f6a7b8/);
    expect(out).toContain('Authorization: [redacted]');
    expect(scrub('header Bearer abcdef0123456789xyz')).toBe('header Bearer [redacted]');
    expect(out).toContain('[jwt]');
    expect(out).toContain('[key]');
    expect(out).toContain('[token]');
  });

  it('redacts given secrets, raw and URL-encoded', () => {
    const s = 'p@ss/word+1';
    expect(scrub(`x ${s} y ${encodeURIComponent(s)}`, [s])).toBe('x [redacted] y [redacted]');
  });

  it('leaves ordinary text and uuids alone', () => {
    expect(scrub('order 0f8fad5b-d9cb-469f-a165-70867728950e failed: oversold')).toBe('order 0f8fad5b-d9cb-469f-a165-70867728950e failed: oversold');
  });

  it('scrubError formats and bounds', () => {
    expect(scrubError(new TypeError('bad a@b.co'))).toBe('TypeError: bad [email]');
    expect(scrubError('x'.repeat(5000)).length).toBe(1000);
    expect(scrubError({ email: 'a@b.co' })).toBe('{"email":"[email]"}');
  });
});

describe('Sentry DSN', () => {
  it('parses the key, host and project; the key never goes in the URL', () => {
    const d = parseSentryDsn(DSN)!;
    expect(d).toEqual({ key: 'abc123publickey', origin: 'https://o42.ingest.us.sentry.io', projectId: '4507' });
    expect(sentryStoreUrl(d)).toBe('https://o42.ingest.us.sentry.io/api/4507/store/');
    expect(sentryStoreUrl(d)).not.toContain('abc123publickey');
    expect(parseSentryDsn('not a dsn')).toBeNull();
    expect(parseSentryDsn('https://o42.ingest.sentry.io/4507')).toBeNull();
  });
});

describe('reportError (browser)', () => {
  it('without a DSN: console only, nothing sent', () => {
    const f = vi.fn();
    vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(configureErrorReporting({ dsn: null, fetch: f })).toBe(false);
    reportError(new Error('boom'), { source: 'test' });
    expect(f).not.toHaveBeenCalled();
  });

  it('with a DSN: one scrubbed POST per distinct message, key in the header', () => {
    const f = vi.fn(async () => new Response(null, { status: 200 }));
    vi.spyOn(console, 'error').mockImplementation(() => {});
    configureErrorReporting({ dsn: DSN, fetch: f });
    const err = new Error('claim failed for buyer@x.com at https://h.test/bridge/claim/1?k=deadbeefdeadbeefdeadbeefdeadbeef');
    reportError(err, { source: 'test' });
    reportError(err, { source: 'test' });
    expect(f).toHaveBeenCalledTimes(1);
    const [url, init] = f.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://o42.ingest.us.sentry.io/api/4507/store/');
    expect((init.headers as Record<string, string>)['X-Sentry-Auth']).toContain('sentry_key=abc123publickey');
    const body = String(init.body);
    expect(body).not.toContain('buyer@x.com');
    expect(body).not.toContain('deadbeef');
    expect(JSON.parse(body)).toMatchObject({ level: 'error', platform: 'javascript', tags: { source: 'test' } });
  });

  it('caps reports per page', () => {
    const f = vi.fn(async () => new Response(null));
    vi.spyOn(console, 'error').mockImplementation(() => {});
    configureErrorReporting({ dsn: DSN, fetch: f });
    for (let i = 0; i < 25; i++) reportError(new Error(`e${i}`));
    expect(f).toHaveBeenCalledTimes(10);
  });

  it('global handlers report errors and rejections once installed', () => {
    const f = vi.fn(async () => new Response(null));
    vi.spyOn(console, 'error').mockImplementation(() => {});
    configureErrorReporting({ dsn: DSN, fetch: f });
    const handlers: Record<string, (e: Event) => void> = {};
    const target = { addEventListener: (t: string, h: (e: Event) => void) => { handlers[t] = h; } } as unknown as Window;
    installGlobalErrorHandlers(target);
    handlers.error({ error: new Error('onerror'), message: 'onerror' } as unknown as Event);
    handlers.unhandledrejection({ reason: new Error('rejected') } as unknown as Event);
    handlers.error({ message: '' } as unknown as Event); // a resource error: ignored
    expect(f).toHaveBeenCalledTimes(2);
  });
});

describe('edge reportError (_shared/log.ts)', () => {
  const envOf = (vars: Record<string, string>) => ({ get: (k: string) => vars[k], all: () => vars });

  it('redacts every secret-looking env value, and posts only with SENTRY_DSN', async () => {
    const vars = { STRIPE_SECRET_KEY: 'sk_live_verysecretvalue', GAMETIME_API_KEY: 'gt-plain-key-42', CRON_SECRET: 'cron-s3cret', SUPABASE_URL: 'https://x.supabase.co' };
    expect(secretValues(vars).sort()).toEqual(['cron-s3cret', 'gt-plain-key-42', 'sk_live_verysecretvalue'].sort());
    const log = vi.fn();
    const f = vi.fn(async () => new Response(null));
    await reportEdgeError('exos-x', new Error('boom gt-plain-key-42 cron-s3cret'), {}, { env: envOf(vars), fetch: f, log });
    expect(String(log.mock.calls[0][0])).toBe('exos-x: Error: boom [redacted] [redacted]');
    expect(f).not.toHaveBeenCalled();
    await reportEdgeError('exos-x', new Error('boom'), { phase: 'p' }, { env: envOf({ ...vars, SENTRY_DSN: DSN }), fetch: f, log });
    expect(f).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(f.mock.calls[0])).not.toContain('gt-plain-key-42');
    expect(redactError(new Error('k=gt-plain-key-42'), { env: envOf(vars) })).not.toContain('gt-plain-key-42');
  });

  it('a failing Sentry POST never throws', async () => {
    const f = vi.fn(async () => { throw new Error('offline'); });
    await expect(reportEdgeError('exos-x', new Error('boom'), {}, { env: envOf({ SENTRY_DSN: DSN }), fetch: f, log: () => {} })).resolves.toBeUndefined();
  });
});
