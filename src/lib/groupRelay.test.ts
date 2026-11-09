import { describe, expect, it } from 'vitest';
import { safeEqual, sendSms, telnyxVerified, twilioSignature } from '../../supabase/functions/_shared/sms/providers.ts';
import {
  e164, formatRelayBody, parseTelnyxRelay, parseTwilioRelay, relayConsentText, relayFirstName, relayKeyword, relayLive,
  relayRoute, relaySenderConfig,
} from '../../supabase/functions/_shared/sms/relay.ts';

// The masked SMS relay (mig 20261031230000): keyword routing, inbound parsing,
// provider signatures (fixtures), and what a relayed text looks like.

describe('relayKeyword', () => {
  it('classifies the carrier keywords, whole message only', () => {
    expect(relayKeyword('STOP')).toBe('stop');
    expect(relayKeyword(' stop. ')).toBe('stop');
    expect(relayKeyword('Unsubscribe')).toBe('stop');
    expect(relayKeyword('cancel')).toBe('stop');
    expect(relayKeyword('STOPALL')).toBe('stop_all');
    expect(relayKeyword('stop  all!')).toBe('stop_all');
    expect(relayKeyword('start')).toBe('start');
    expect(relayKeyword('UNSTOP')).toBe('start');
    expect(relayKeyword('help')).toBe('help');
    expect(relayKeyword('Info?')).toBe('help');
  });
  it('leaves ordinary messages alone', () => {
    expect(relayKeyword('yes')).toBeNull();          // a chat "yes" is not START
    expect(relayKeyword('please stop texting about pizza')).toBeNull();
    expect(relayKeyword('')).toBeNull();
    expect(relayKeyword(null)).toBeNull();
    expect(relayKeyword('help me find the table')).toBeNull();
  });
});

describe('routing', () => {
  it('maps paths to routes', () => {
    expect(relayRoute('/functions/v1/exos-sms-relay/inbound/twilio')).toEqual({ kind: 'inbound', provider: 'twilio' });
    expect(relayRoute('/exos-sms-relay/inbound/telnyx/')).toEqual({ kind: 'inbound', provider: 'telnyx' });
    expect(relayRoute('/exos-sms-relay/cron')).toEqual({ kind: 'cron' });
    expect(relayRoute('/exos-sms-relay/inbound/vonage')).toBeNull();
    expect(relayRoute('/exos-sms-relay/twilio')).toBeNull();
  });

  it('parses Twilio inbound into (from, to): the routing key', () => {
    expect(parseTwilioRelay({ From: '+12125550101', To: '+13325550001', Body: 'hi', MessageSid: 'SM' + 'a'.repeat(32) }))
      .toEqual({ from: '+12125550101', to: '+13325550001', text: 'hi', id: 'SM' + 'a'.repeat(32) });
    expect(parseTwilioRelay({ From: '2125550101', To: '13325550001', Body: 'x' })?.to).toBe('+13325550001');
    expect(parseTwilioRelay({ From: 'not a phone', To: '+13325550001', Body: 'x' })).toBeNull();
    expect(parseTwilioRelay({ From: '+12125550101', To: '+13325550001', MessageSid: '../../x' })?.id).toBeNull();
  });

  it('parses Telnyx message.received only', () => {
    const body = { data: { event_type: 'message.received', payload: { id: 'abc', from: { phone_number: '+12125550101' }, to: [{ phone_number: '+13325550003' }], text: 'yo' } } };
    expect(parseTelnyxRelay(body)).toEqual({ from: '+12125550101', to: '+13325550003', text: 'yo', id: 'telnyx:abc' });
    expect(parseTelnyxRelay({ data: { event_type: 'message.sent', payload: body.data.payload } })).toBeNull();
    expect(parseTelnyxRelay({ data: { event_type: 'message.received', payload: { from: { phone_number: '+12125550101' } } } })).toBeNull();
  });

  it('normalizes numbers like exos_sms_normalize_phone', () => {
    expect(e164('(212) 555-0101')).toBe('+12125550101');
    expect(e164('+44 7700 900123')).toBe('+447700900123');
    expect(e164('555-0101')).toBeNull();
  });
});

describe('signatures (fixtures)', () => {
  it('Twilio: matches Twilio\'s documented example and catches tampering', async () => {
    // https://www.twilio.com/docs/usage/security#validating-requests
    const params = { CallSid: 'CA1234567890ABCDE', Caller: '+12349013030', Digits: '1234', From: '+12349013030', To: '+18005551212' };
    const sig = await twilioSignature('https://mycompany.com/myapp.php?foo=1&bar=2', params, '12345');
    expect(sig).toBe('0/KCTR6DLpKmkAf8muzZqo1nDgQ=');
    expect(safeEqual(sig, '0/KCTR6DLpKmkAf8muzZqo1nDgQ=')).toBe(true);
    const tampered = await twilioSignature('https://mycompany.com/myapp.php?foo=1&bar=2', { ...params, Digits: '1235' }, '12345');
    expect(safeEqual(sig, tampered)).toBe(false);
    const otherUrl = await twilioSignature('https://mycompany.com/myapp.php?foo=1&bar=3', params, '12345');
    expect(safeEqual(sig, otherUrl)).toBe(false);
    expect(safeEqual(sig, '')).toBe(false);
  });

  // A message.received event signed once with a throwaway Ed25519 key.
  const TELNYX = {
    pub: 'NnysQdDt71y9xsgUKpPxsrCIWx34Nbe3zTxqi9N/qPc=',
    ts: '1793376000',
    body: '{"data":{"event_type":"message.received","payload":{"id":"b301ed3f-1490-491f-995f-6e64e69674d4","from":{"phone_number":"+12125550101"},"to":[{"phone_number":"+13325550003"}],"text":"see you at 9"}}}',
    sig: '8SD0juNDqRPjnQWY6bKqytusIsoz2dnbeUVRWJsY8a0hUyobn3xVQgdsgisAjAJAQSjD985iQY5/dgygicK3AQ==',
  };
  const at = (s: number) => (Number(TELNYX.ts) + s) * 1000;

  it('Telnyx: verifies the fixture inside the 5-minute window', async () => {
    expect(await telnyxVerified(TELNYX.body, TELNYX.sig, TELNYX.ts, TELNYX.pub, at(60))).toBe(true);
    expect(parseTelnyxRelay(JSON.parse(TELNYX.body))?.to).toBe('+13325550003');
  });
  it('Telnyx: refuses a changed body, timestamp, key, or a stale request', async () => {
    expect(await telnyxVerified(TELNYX.body.replace('9', '8'), TELNYX.sig, TELNYX.ts, TELNYX.pub, at(60))).toBe(false);
    expect(await telnyxVerified(TELNYX.body, TELNYX.sig, String(Number(TELNYX.ts) + 1), TELNYX.pub, at(60))).toBe(false);
    expect(await telnyxVerified(TELNYX.body, TELNYX.sig, TELNYX.ts, btoa('x'.repeat(32)), at(60))).toBe(false);
    expect(await telnyxVerified(TELNYX.body, TELNYX.sig, TELNYX.ts, TELNYX.pub, at(301))).toBe(false);
    expect(await telnyxVerified(TELNYX.body, 'garbage', TELNYX.ts, TELNYX.pub, at(60))).toBe(false);
  });
});

describe('formatRelayBody (matches exos_relay_format)', () => {
  it('first name, links out, whitespace collapsed', () => {
    expect(formatRelayBody('Mo  Sender', 'hey all see https://evil.example/x ok')).toBe('Mo: hey all see [link in app] ok');
    expect(formatRelayBody('  Jo-Ann  Smith ', 'hi\n\nthere www.x.com/y')).toBe('Jo-Ann: hi there [link in app]');
    expect(formatRelayBody('', 'x')).toBe('Member: x');
    expect(formatRelayBody('<script>', 'x')).toBe('script: x');
    expect(relayFirstName('Ana')).toBe('Ana');
  });
  it('caps at 306 characters (two segments)', () => {
    const out = formatRelayBody('Al', 'y'.repeat(400));
    expect(out).toHaveLength(306);
    expect(out.endsWith('...')).toBe(true);
    expect(formatRelayBody('Al', 'y'.repeat(302))).toHaveLength(306);
  });
});

describe('sending (provider mock)', () => {
  it('uses the platform account and the member\'s pool number as the sender', async () => {
    const env = (k: string) => ({ EXOS_RELAY_TWILIO_ACCOUNT_SID: 'AC' + 'b'.repeat(32), EXOS_RELAY_TWILIO_AUTH_TOKEN: 'tok', EXOS_SMS_RELAY: 'off' } as Record<string, string>)[k];
    const cfg = relaySenderConfig('twilio', '+13325550001', env)!;
    const calls: { url: string; body: string }[] = [];
    const mock = ((url: string, init?: RequestInit) => {
      calls.push({ url, body: String(init?.body) });
      return Promise.resolve(new Response(JSON.stringify({ sid: 'SM1' }), { status: 201 }));
    }) as unknown as typeof fetch;
    expect(await sendSms(mock, cfg, '+12125550102', 'Mo: hi')).toEqual({ ok: true, id: 'SM1' });
    expect(calls[0].url).toContain('/Accounts/AC' + 'b'.repeat(32) + '/Messages.json');
    expect(calls[0].body).toContain('From=%2B13325550001');
    expect(relayLive(env)).toBe(false);
    expect(relayLive((k) => (k === 'EXOS_SMS_RELAY' ? 'on' : undefined))).toBe(true);
    expect(relaySenderConfig('telnyx', '+13325550003', env)).toBeNull();
    expect(relaySenderConfig('vonage', '+13325550003', env)).toBeNull();
  });
  it('consent text names STOP and HELP (the SQL requires both)', () => {
    const t = relayConsentText('Table 4');
    expect(t).toMatch(/STOP/);
    expect(t).toMatch(/HELP/);
    expect(t.length).toBeLessThanOrEqual(600);
  });
});
