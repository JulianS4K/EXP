// ActivityPub federation (supabase/functions/_shared/activitypub/*, mig 20261031200000).
import { describe, it, expect, vi } from 'vitest';
import {
  digestHeader, parseSignatureHeader, signingString, signRequest, verifyRequest, generateActorKeyPair,
} from '../../supabase/functions/_shared/activitypub/signature.ts';
import { guardedFetch, fetchApJson, readCapped } from '../../supabase/functions/_shared/activitypub/fetchGuard.ts';
import {
  webfinger, parseAcct, groupActor, personActor, postObject, eventObject, announceFor, deleteFor, acceptFollow,
  ourObject, ourGroup, htmlToText, textToHtml, parseRemoteActor, softwareName, orgApName, AS_PUBLIC,
  type PostRow, type EventRow, type Urls,
} from '../../supabase/functions/_shared/activitypub/objects.ts';

// ── Test vector, signed by OpenSSL (an independent implementation) ──────────
// openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048; the signing
// string below; `openssl dgst -sha256 -sign`. Only the public half is kept here.
const VECTOR = {
  publicPem:
    '-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzykuuAgn5LSeUnCoMxf5\ngA4IIOjzQy6ds3e6YsMom+x/w9UHX8AFl2zaz16+XvBGgCeW7efb8S7dBpNIq3/c\n5cfzigFLpYdcn+bR8/qHGUjj5/pgZyIMGecpfEeixKlPzmlzrv8+d4mReRpSNwid\nyLdjlotfovgRYc/KNx+v2ozCy8H/uMChK12Zk7BQn5BQO+MK3BmXwYh2bFCe8kYX\nzLTmrsw00X4pTuBSYWu4EyCn1OVKDbJptEPpG0iv3zhdv/qoNY1O2D1BQnNDzNPB\ncvAusdG1Imwo0HXSmWYDO8WXjTO8vwp1KLaszGGXtZjZVhHM/wXCMQN+4r6PK4Cj\nAwIDAQAB\n-----END PUBLIC KEY-----\n',
  body: '{"type":"Follow","actor":"https://remote.example/users/alice","object":"https://exos.example/ap/c/bar_run_club"}',
  digest: 'SHA-256=uUJnwbvlR0efdc6RWTjkFZU7BOx3xJ+yx4wsjGatO94=',
  date: 'Fri, 30 Oct 2026 12:00:00 GMT',
  signature:
    'OS/bY2NjGk9BsXWpG2C8Twps9NiH3zoQzOKP4sIQorK5msnZgFo6qXTBG/gNvio3JVZHwgWn9YV33BE/6ZykUO2hpbESZDcw9ldIoWtk6YBvTnSQIrh8S6PvWmMwmcFwosbwm3NGnsttrkvIhu2WF7BETLCR29CE6xmtSpcKY+nDC9dMup7+6KZD5HyYATKzsYy0mnm+fbTC0add4MdeQmxo8ObFDf6232YkhooR2pmLTS/LJuuhXmghYBQEOwixinVIDsgeeQoMCrrFATV45FN0SWOktjYFenUUDDAd5Wr4s/QIG7m9MSBn8JON4yUjvd9acp4NeCxaqYOMPAaGAg==',
};
const PATH = '/ap/c/bar_run_club/inbox';
const NOW = new Date('2026-10-30T12:03:00Z');
const vectorHeaders = (over: Record<string, string> = {}) => ({
  Host: 'exos.example',
  Date: VECTOR.date,
  Digest: VECTOR.digest,
  'Content-Type': 'application/activity+json',
  Signature: `keyId="https://remote.example/users/alice#main-key",algorithm="rsa-sha256",headers="(request-target) host date digest",signature="${VECTOR.signature}"`,
  ...over,
});

describe('HTTP signatures (draft-cavage, RSA-SHA256)', () => {
  it('computes the same SHA-256 digest as OpenSSL', async () => {
    expect(await digestHeader(VECTOR.body)).toBe(VECTOR.digest);
    expect(await digestHeader('')).toBe('SHA-256=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=');
  });

  it('builds the signing string', () => {
    expect(signingString('POST', PATH, { Host: 'exos.example', Date: VECTOR.date, Digest: VECTOR.digest },
      ['(request-target)', 'host', 'date', 'digest'])).toBe(
      `(request-target): post ${PATH}\nhost: exos.example\ndate: ${VECTOR.date}\ndigest: ${VECTOR.digest}`);
    expect(() => signingString('GET', '/', {}, ['date'])).toThrow('date');
  });

  it('parses Signature headers and refuses junk', () => {
    const p = parseSignatureHeader(vectorHeaders().Signature);
    expect(p).toEqual({
      keyId: 'https://remote.example/users/alice#main-key', algorithm: 'rsa-sha256',
      headers: ['(request-target)', 'host', 'date', 'digest'], signature: VECTOR.signature,
    });
    expect(parseSignatureHeader('Signature keyId="k", signature="c2ln"')?.headers).toEqual(['date']);
    expect(parseSignatureHeader('keyId=k,signature=x')).toBeNull();
    expect(parseSignatureHeader('keyId="k"')).toBeNull();
    expect(parseSignatureHeader('x'.repeat(5000))).toBeNull();
    expect(parseSignatureHeader(null)).toBeNull();
  });

  it('verifies the OpenSSL-signed vector', async () => {
    const r = await verifyRequest({ method: 'POST', pathWithQuery: PATH, headers: vectorHeaders(), body: VECTOR.body, publicKey: VECTOR.publicPem, now: NOW });
    expect(r).toEqual({ ok: true, keyId: 'https://remote.example/users/alice#main-key' });
    // Lemmy labels the same RSA-SHA256 "hs2019".
    const hs = vectorHeaders({ Signature: vectorHeaders().Signature.replace('rsa-sha256', 'hs2019') });
    expect((await verifyRequest({ method: 'POST', pathWithQuery: PATH, headers: hs, body: VECTOR.body, publicKey: VECTOR.publicPem, now: NOW })).ok).toBe(true);
  });

  it('refuses tampering, skew, weak header sets and other algorithms', async () => {
    const base = { method: 'POST', pathWithQuery: PATH, body: VECTOR.body, publicKey: VECTOR.publicPem, now: NOW };
    const reason = async (o: Partial<Parameters<typeof verifyRequest>[0]>) => {
      const r = await verifyRequest({ ...base, headers: vectorHeaders(), ...o });
      return r.ok ? 'ok' : r.reason;
    };
    expect(await reason({ body: VECTOR.body.replace('alice', 'mallory') })).toBe('digest mismatch');
    expect(await reason({ headers: vectorHeaders({ Digest: 'SHA-256=' + 'A'.repeat(43) + '=' }) })).toBe('digest mismatch');
    expect(await reason({ pathWithQuery: '/ap/c/other/inbox' })).toBe('signature does not verify');
    expect(await reason({ headers: vectorHeaders({ Host: 'evil.example' }) })).toBe('signature does not verify');
    expect(await reason({ now: new Date('2026-10-30T14:00:01Z') })).toBe('date out of range');
    expect(await reason({ now: new Date('2026-10-30T10:00:00Z') })).toBe('date out of range');
    expect(await reason({ headers: vectorHeaders({ Date: 'yesterday-ish' }) })).toBe('bad date');
    const noDigest = vectorHeaders({ Signature: vectorHeaders().Signature.replace(' digest"', '"') });
    expect(await reason({ headers: noDigest })).toBe('digest not signed');
    const noHost = vectorHeaders({ Signature: vectorHeaders().Signature.replace(' host', '') });
    expect(await reason({ headers: noHost })).toBe('host not signed');
    const hmac = vectorHeaders({ Signature: vectorHeaders().Signature.replace('rsa-sha256', 'hmac-sha256') });
    expect(await reason({ headers: hmac })).toBe('algorithm hmac-sha256 not accepted');
    expect(await reason({ headers: { ...vectorHeaders(), Signature: '' } })).toBe('no signature');
    expect(await reason({ publicKey: '-----BEGIN PUBLIC KEY-----\nQUJD\n-----END PUBLIC KEY-----' })).toBe('bad public key');
  });

  it('signs a POST that verifies, and a GET without a digest', async () => {
    const { publicPem, privatePem } = await generateActorKeyPair();
    expect(publicPem).toMatch(/^-----BEGIN PUBLIC KEY-----\n/);
    expect(privatePem).toMatch(/^-----BEGIN PRIVATE KEY-----\n/);
    const body = JSON.stringify({ type: 'Accept' });
    const date = new Date('2026-10-30T12:00:00Z');
    const h = await signRequest({
      method: 'POST', url: 'https://lemmy.example/inbox?x=1', body, keyId: 'https://exos.example/ap/c/a_b#main-key',
      privateKey: privatePem, headers: { 'content-type': 'application/activity+json' }, date,
    });
    expect(h.host).toBe('lemmy.example');
    expect(h.date).toBe('Fri, 30 Oct 2026 12:00:00 GMT');
    expect(h.digest).toBe(await digestHeader(body));
    expect(h.signature).toMatch(/^keyId="https:\/\/exos\.example\/ap\/c\/a_b#main-key",algorithm="rsa-sha256",headers="\(request-target\) host date digest content-type",signature="[A-Za-z0-9+/=]+"$/);
    expect((await verifyRequest({ method: 'POST', pathWithQuery: '/inbox?x=1', headers: h, body, publicKey: publicPem, now: date })).ok).toBe(true);
    expect((await verifyRequest({ method: 'POST', pathWithQuery: '/inbox', headers: h, body, publicKey: publicPem, now: date })).ok).toBe(false);
    const g = await signRequest({ method: 'GET', url: 'https://lemmy.example/u/alice', keyId: 'k', privateKey: privatePem, date });
    expect(g.digest).toBeUndefined();
    expect(parseSignatureHeader(g.signature)?.headers).toEqual(['(request-target)', 'host', 'date']);
    expect((await verifyRequest({ method: 'GET', pathWithQuery: '/u/alice', headers: g, body: null, publicKey: publicPem, now: date })).ok).toBe(true);
    // Another key doesn't verify it.
    const other = await generateActorKeyPair();
    expect((await verifyRequest({ method: 'GET', pathWithQuery: '/u/alice', headers: g, body: null, publicKey: other.publicPem, now: date })).ok).toBe(false);
  });
});

// ── JSON shapes ─────────────────────────────────────────────────────────────
const U: Urls = { origin: 'https://exos.example', appBase: 'https://exos.example/bridge' };
const PEM = '-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----\n';
const P1 = '11111111-1111-4111-8111-111111111111';
const E1 = '22222222-2222-4222-8222-222222222222';
const community = { ap_name: 'bar_run_club', slug: 'bar-run-club', name: 'Bar Run Club' };
const post = (over: Partial<PostRow> = {}): PostRow => ({
  kind: 'post', id: P1, title: 'Route change', body: 'We start <at> the bar.\n\nSee you', created_at: '2026-10-30T10:00:00Z',
  community, org: { slug: 'corner-bar', name: 'Corner Bar' }, ...over,
});
const event = (over: Partial<EventRow> = {}): EventRow => ({
  kind: 'event', id: E1, name: 'Saturday 5K', starts_at: '2026-11-07T13:00:00Z', ends_at: '2026-11-07T15:00:00Z',
  timezone: 'America/New_York', venue_name: 'Corner Bar', venue_location: 'Brooklyn, NY', description: 'Easy pace',
  created_at: '2026-10-30T10:00:00Z', community, org: { slug: 'corner-bar', name: 'Corner Bar' }, ...over,
});

describe('WebFinger and actors', () => {
  it('parses acct resources for our host only', () => {
    expect(parseAcct('acct:bar_run_club@exos.example', 'exos.example')).toBe('bar_run_club');
    expect(parseAcct('acct:Bar_Run_Club@EXOS.example', 'exos.example')).toBe('bar_run_club');
    expect(parseAcct('!bar_run_club@exos.example', 'exos.example')).toBe('bar_run_club');
    expect(parseAcct('https://exos.example/ap/c/bar_run_club', 'exos.example')).toBe('bar_run_club');
    expect(parseAcct('acct:bar_run_club@evil.example', 'exos.example')).toBeNull();
    expect(parseAcct('acct:bar-run-club@exos.example', 'exos.example')).toBeNull();
    expect(parseAcct('acct:@exos.example', 'exos.example')).toBeNull();
    expect(parseAcct('https://evil.example/ap/c/bar_run_club', 'exos.example')).toBeNull();
    expect(parseAcct(null, 'exos.example')).toBeNull();
  });

  it('answers WebFinger with the Group self link', () => {
    const w = webfinger(U, 'bar_run_club', 'community', 'https://exos.example/bridge/c/bar-run-club');
    expect(w.subject).toBe('acct:bar_run_club@exos.example');
    const self = w.links.find((l) => l.rel === 'self')!;
    expect(self).toEqual({
      rel: 'self', type: 'application/activity+json', href: 'https://exos.example/ap/c/bar_run_club',
      properties: { 'https://www.w3.org/ns/activitystreams#type': 'Group' },
    });
    expect(w.links.find((l) => l.rel === 'http://webfinger.net/rel/profile-page')?.href).toBe('https://exos.example/bridge/c/bar-run-club');
  });

  it('builds a Lemmy-shaped Group actor', () => {
    const g = groupActor(U, { ...community, tagline: 'Run, then <b>a pint</b>', about: null, banner_url: 'https://cdn.example/b.jpg',
      created_at: '2026-10-01T00:00:00Z', public_key_pem: PEM });
    expect(g).toMatchObject({
      type: 'Group', id: 'https://exos.example/ap/c/bar_run_club', preferredUsername: 'bar_run_club', name: 'Bar Run Club',
      inbox: 'https://exos.example/ap/c/bar_run_club/inbox', outbox: 'https://exos.example/ap/c/bar_run_club/outbox',
      followers: 'https://exos.example/ap/c/bar_run_club/followers', attributedTo: 'https://exos.example/ap/c/bar_run_club/moderators',
      url: 'https://exos.example/bridge/c/bar-run-club', endpoints: { sharedInbox: 'https://exos.example/ap/inbox' },
      publicKey: { id: 'https://exos.example/ap/c/bar_run_club#main-key', owner: 'https://exos.example/ap/c/bar_run_club', publicKeyPem: PEM },
      image: { type: 'Image', url: 'https://cdn.example/b.jpg' }, published: '2026-10-01T00:00:00.000Z', manuallyApprovesFollowers: false,
    });
    expect(g.summary).toBe('<p>Run, then &lt;b&gt;a pint&lt;/b&gt;</p>');
    expect((g['@context'] as unknown[])[0]).toBe('https://www.w3.org/ns/activitystreams');
    expect(() => groupActor(U, { ...community, ap_name: 'Bad-Name', public_key_pem: PEM })).toThrow();
    expect(groupActor(U, { ...community, banner_url: 'http://x', public_key_pem: PEM }).image).toBeUndefined();
  });

  it('builds the org Person (post author)', () => {
    expect(orgApName('corner-bar')).toBe('org_corner_bar');
    const p = personActor(U, { ap_name: 'org_corner_bar', slug: 'corner-bar', name: 'Corner Bar', public_key_pem: PEM });
    expect(p).toMatchObject({ type: 'Person', id: 'https://exos.example/ap/o/org_corner_bar', inbox: 'https://exos.example/ap/inbox',
      url: 'https://exos.example/bridge/o/corner-bar', publicKey: { owner: 'https://exos.example/ap/o/org_corner_bar' } });
  });
});

describe('objects and activities', () => {
  it('titled posts are Pages, untitled are Notes, text is escaped', () => {
    const page = postObject(U, post());
    expect(page).toMatchObject({ type: 'Page', name: 'Route change', id: `https://exos.example/ap/p/${P1}`,
      attributedTo: 'https://exos.example/ap/o/org_corner_bar', audience: 'https://exos.example/ap/c/bar_run_club',
      to: [AS_PUBLIC, 'https://exos.example/ap/c/bar_run_club'], cc: ['https://exos.example/ap/c/bar_run_club/followers'] });
    expect(page.content).toBe('<p>We start &lt;at&gt; the bar.</p><p>See you</p>');
    const note = postObject(U, post({ title: null }));
    expect(note.type).toBe('Note');
    expect('name' in note).toBe(false);
    expect(() => postObject(U, post({ id: 'not-a-uuid' }))).toThrow();
  });

  it('events are Event objects with time and place', () => {
    const e = eventObject(U, event());
    expect(e).toMatchObject({ type: 'Event', name: 'Saturday 5K', startTime: '2026-11-07T13:00:00.000Z', endTime: '2026-11-07T15:00:00.000Z',
      url: `https://exos.example/bridge/event/${E1}`, location: { type: 'Place', name: 'Corner Bar', address: 'Brooklyn, NY' } });
    expect(String(e.content)).toContain('Tickets</a>');
  });

  it('announces per follower style', () => {
    const m = announceFor(U, post(), 'object')!;
    expect(m).toMatchObject({ type: 'Announce', actor: 'https://exos.example/ap/c/bar_run_club', to: [AS_PUBLIC] });
    expect((m.object as Record<string, unknown>).type).toBe('Page');
    expect('@context' in (m.object as object)).toBe(false);
    const l = announceFor(U, post(), 'activity')!;
    const create = l.object as Record<string, unknown>;
    expect(create).toMatchObject({ type: 'Create', actor: 'https://exos.example/ap/o/org_corner_bar', audience: 'https://exos.example/ap/c/bar_run_club' });
    expect((create.object as Record<string, unknown>).type).toBe('Page');
    expect(announceFor(U, post({ title: null }), 'activity')).toBeNull();
    expect(((announceFor(U, event(), 'activity')!.object as Record<string, unknown>).object as Record<string, unknown>).type).toBe('Page');
    expect((announceFor(U, event(), 'object')!.object as Record<string, unknown>).type).toBe('Event');
    expect(m.id).not.toBe(l.id);
  });

  it('deletes: author Delete for Mastodon, announced Delete for Lemmy', () => {
    const m = deleteFor(U, post(), 'object');
    expect(m.signer).toBe('org');
    expect(m.activity).toMatchObject({ type: 'Delete', actor: 'https://exos.example/ap/o/org_corner_bar', object: { type: 'Tombstone' } });
    const l = deleteFor(U, post(), 'activity');
    expect(l.signer).toBe('community');
    expect(l.activity).toMatchObject({ type: 'Announce', object: { type: 'Delete', object: `https://exos.example/ap/p/${P1}` } });
  });

  it('accepts a Follow with a stable id', () => {
    const f = { id: 'https://lemmy.example/activities/follow/1', type: 'Follow', actor: 'https://lemmy.example/u/alice', object: 'x' };
    const a = acceptFollow(U, 'bar_run_club', f);
    expect(a).toMatchObject({ type: 'Accept', actor: 'https://exos.example/ap/c/bar_run_club', to: ['https://lemmy.example/u/alice'],
      object: { type: 'Follow', id: f.id, actor: f.actor, object: 'https://exos.example/ap/c/bar_run_club' } });
    expect(acceptFollow(U, 'bar_run_club', f).id).toBe(a.id);
  });

  it('maps inbound references to our objects only', () => {
    expect(ourObject(U, `https://exos.example/ap/p/${P1}`)).toEqual({ kind: 'post', id: P1 });
    expect(ourObject(U, { id: `https://exos.example/ap/e/${E1}/page` })).toEqual({ kind: 'event', id: E1 });
    expect(ourObject(U, `https://evil.example/ap/p/${P1}`)).toBeNull();
    expect(ourObject(U, `https://exos.example/ap/p/${P1}/../x`)).toBeNull();
    expect(ourGroup(U, 'https://exos.example/ap/c/bar_run_club')).toBe('bar_run_club');
    expect(ourGroup(U, 'https://exos.example/ap/c/bar_run_club/inbox')).toBe('bar_run_club');
    expect(ourGroup(U, 'https://exos.example.evil/ap/c/bar_run_club')).toBeNull();
  });

  it('reduces remote HTML to plain text', () => {
    expect(htmlToText('<p>Hi <a href="x">@bob</a></p><script>alert(1)</script><p>2 &lt; 3 &amp; ok</p>')).toBe('Hi @bob\n2 < 3 & ok');
    expect(htmlToText('<img src=x onerror=alert(1)>')).toBe('');
    expect(htmlToText('a'.repeat(6000)).length).toBe(5000);
    expect(textToHtml('<script>')).toBe('<p>&lt;script&gt;</p>');
  });

  it('validates remote actors: key owner and host must match', () => {
    const doc = { id: 'https://masto.example/users/carol', type: 'Person', preferredUsername: 'carol', name: 'Carol',
      inbox: 'https://masto.example/users/carol/inbox', endpoints: { sharedInbox: 'https://masto.example/inbox' },
      publicKey: { id: 'https://masto.example/users/carol#main-key', owner: 'https://masto.example/users/carol', publicKeyPem: PEM } };
    expect(parseRemoteActor(doc, doc.id)).toMatchObject({ handle: '@carol@masto.example', sharedInbox: 'https://masto.example/inbox' });
    expect(parseRemoteActor(doc, 'https://masto.example/users/dave')).toBeNull();
    expect(parseRemoteActor({ ...doc, publicKey: { ...doc.publicKey, owner: 'https://masto.example/users/dave' } }, doc.id)).toBeNull();
    expect(parseRemoteActor({ ...doc, publicKey: { ...doc.publicKey, id: 'https://evil.example/k' } }, doc.id)).toBeNull();
    expect(parseRemoteActor({ ...doc, inbox: 'https://evil.example/inbox' }, doc.id)).toBeNull();
    expect(parseRemoteActor({ ...doc, endpoints: { sharedInbox: 'https://evil.example/inbox' } }, doc.id)?.sharedInbox).toBeNull();
    expect(softwareName({ software: { name: 'Lemmy' } })).toBe('lemmy');
    expect(softwareName({ software: { name: '<x>' } })).toBeNull();
  });
});

// ── SSRF guard ──────────────────────────────────────────────────────────────
const res = (status: number, body = '', headers: Record<string, string> = {}) => new Response(status === 204 || (status >= 300 && status < 400) ? null : body, { status, headers });
const publicDns = async () => ['93.184.216.34'];

describe('SSRF-guarded fetch', () => {
  it('fetches a public https URL', async () => {
    const f = vi.fn(async () => res(200, '{"id":"https://a.example/u/x"}', { 'content-type': 'application/activity+json' }));
    const r = await fetchApJson('https://a.example/u/x', { resolve: publicDns, fetchImpl: f });
    expect(r.ok).toBe(true);
    expect(f).toHaveBeenCalledTimes(1);
    expect((f.mock.calls[0] as unknown as [string, RequestInit])[1].redirect).toBe('manual');
  });

  it.each([
    ['http://a.example/x', 'non-https'],
    ['https://127.0.0.1/x', 'private ip'],
    ['https://[::1]/x', 'private ip'],
    ['https://169.254.169.254/latest/meta-data', 'private ip'],
    ['https://[::ffff:10.0.0.1]/x', 'private ip'],
    ['https://localhost/x', 'internal host'],
    ['https://db.internal/x', 'internal host'],
    ['https://user:pw@a.example/x', 'credentials'],
  ])('refuses %s before any request', async (url, why) => {
    const f = vi.fn();
    const r = await guardedFetch(url, { resolve: publicDns, fetchImpl: f });
    expect(r.ok).toBe(false);
    expect(r.blocked).toBe(true);
    expect(r.error).toContain(why);
    expect(f).not.toHaveBeenCalled();
  });

  it('refuses a name that resolves to a private address (any record)', async () => {
    const f = vi.fn();
    const r = await guardedFetch('https://sneaky.example/x', { resolve: async () => ['93.184.216.34', '10.1.2.3'], fetchImpl: f });
    expect(r.error).toContain('private ip 10.1.2.3');
    expect(f).not.toHaveBeenCalled();
  });

  it('re-checks every redirect hop and stops at a private one', async () => {
    const f = vi.fn(async (url: string) => url.includes('start')
      ? res(302, '', { location: 'https://rebind.example/next' })
      : res(200, 'secret'));
    const resolve = async (h: string) => (h === 'rebind.example' ? ['192.168.1.5'] : ['93.184.216.34']);
    const r = await guardedFetch('https://a.example/start', { resolve, fetchImpl: f });
    expect(r.ok).toBe(false);
    expect(r.error).toContain('private ip 192.168.1.5');
    expect(f).toHaveBeenCalledTimes(1);
  });

  it('caps redirects; POST never follows them', async () => {
    const loop = vi.fn(async () => res(301, '', { location: 'https://a.example/again' }));
    expect((await guardedFetch('https://a.example/x', { resolve: publicDns, fetchImpl: loop, maxRedirects: 2 })).error).toBe('too many redirects');
    expect(loop).toHaveBeenCalledTimes(3);
    const post = vi.fn(async () => res(307, '', { location: 'https://a.example/elsewhere' }));
    const r = await guardedFetch('https://a.example/inbox', { method: 'POST', body: '{}', resolve: publicDns, fetchImpl: post });
    expect(r.error).toBe('too many redirects');
    expect(post).toHaveBeenCalledTimes(1);
  });

  it('caps the body size (declared and streamed)', async () => {
    const big = vi.fn(async () => res(200, 'x'.repeat(2000), { 'content-type': 'application/json' }));
    expect((await guardedFetch('https://a.example/x', { resolve: publicDns, fetchImpl: big, maxBytes: 1000 })).error).toContain('over 1000 bytes');
    const stream = new ReadableStream<Uint8Array>({
      start(c) { for (let i = 0; i < 10; i++) c.enqueue(new Uint8Array(300)); c.close(); },
    });
    await expect(readCapped(new Response(stream), 1000)).rejects.toThrow('over 1000 bytes');
  });

  it('times out', async () => {
    const slow = vi.fn((_u: string, init: RequestInit) => new Promise<Response>((_, reject) => {
      init.signal?.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })));
    }));
    const r = await guardedFetch('https://a.example/x', { resolve: publicDns, fetchImpl: slow, timeoutMs: 20 });
    expect(r.error).toBe('timed out after 20 ms');
  });

  it('only accepts JSON objects as ActivityPub documents', async () => {
    const html = vi.fn(async () => res(200, '<html>', { 'content-type': 'text/html' }));
    expect(await fetchApJson('https://a.example/x', { resolve: publicDns, fetchImpl: html })).toEqual({ ok: false, error: 'not JSON' });
    const arr = vi.fn(async () => res(200, '[]', { 'content-type': 'application/json' }));
    expect(await fetchApJson('https://a.example/x', { resolve: publicDns, fetchImpl: arr })).toEqual({ ok: false, error: 'not an object' });
  });
});
