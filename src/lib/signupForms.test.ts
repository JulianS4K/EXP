// Signup forms (mig 20261031120000): snippets, wording parity with the SQL,
// and the exos-signup body / captcha helpers (supabase/functions/_shared/signup.ts).
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));
import {
  emailConsentText, parsePublicForm, parseSignupForm, signupProblem, signupSnippets, signupToken, smsConsentText,
} from './signupForms';
import {
  captchaConfig, captchaPassed, captchaVerifyRequest, formIdFromPath, parseSignupBody, SignupInputError, truthy,
} from '../../supabase/functions/_shared/signup.ts';

const FORM = '1c3e5a7b-9d1f-4c3e-8a5b-7d9f1b3d5f7a';
const SQL = readFileSync(path.resolve(__dirname, '../../supabase/migrations/20261031120000_exos_fans.sql'), 'utf8');

/** The text a SQL wording function builds for an org name (its two string pieces). */
function sqlWording(fn: string, org: string): string {
  const body = new RegExp(`FUNCTION public\\.${fn}\\(p_org_name text\\)[\\s\\S]*?AS \\$\\$([\\s\\S]*?)\\$\\$`).exec(SQL);
  if (!body) throw new Error(`${fn} not found`);
  const parts = [...body[1].matchAll(/'((?:[^']|'')*)'/g)].map((m) => m[1].replace(/''/g, "'"));
  // 'Text me about ' || org || '''s events …' || '…'
  return parts[0] + org + parts.slice(1).join('');
}

describe('consent wording', () => {
  it('SMS wording is the ticket-page wording, word for word, in the SQL too', () => {
    expect(sqlWording('exos_sms_consent_text', 'The Hall')).toBe(smsConsentText('The Hall'));
    expect(smsConsentText('X')).toContain('Reply STOP to cancel');
  });
  it('email wording matches the SQL', () => {
    expect(sqlWording('exos_signup_email_consent_text', 'The Hall')).toBe(emailConsentText('The Hall'));
  });
});

describe('snippets', () => {
  it('script, iframe and link for a form', () => {
    const s = signupSnippets('https://exos.example/bridge/', FORM, 'Footer --> <b>"x"</b>');
    expect(s.script).toBe(`<!-- Exos signup form — Footer — bx/b -->
<div data-exos-signup="${FORM}"></div>
<script src="https://exos.example/bridge/embed.js" async></script>`);
    expect(s.script.indexOf('-->')).toBe(s.script.lastIndexOf('-->'));
    expect(s.iframe).toContain(`src="https://exos.example/bridge/embed/signup/${FORM}"`);
    expect(s.iframe).toContain('title="Footer — bx/b"');
    expect(s.link).toBe(`https://exos.example/bridge/embed/signup/${FORM}`);
  });
  it('a bad id becomes a placeholder', () => {
    expect(signupSnippets('https://e.x', '"><script>').script).toContain('data-exos-signup="FORM_ID"');
  });
});

describe('parsing and checks', () => {
  it('parses forms', () => {
    expect(parseSignupForm({ id: 'f', name: 'n', title: 't', status: 'weird', default_tag_ids: ['a'], submissions: '3' }))
      .toMatchObject({ status: 'active', defaultTagIds: ['a'], submissions: 3, askName: true, offerSms: false });
    expect(parsePublicForm(null)).toBeNull();
    expect(parsePublicForm({ id: FORM, title: 'Join', offer_sms: true, sms_consent_text: null })?.offerSms).toBe(false);
    expect(parsePublicForm({ id: FORM, title: 'Join', offer_sms: true, sms_consent_text: 'Text me…' })?.buttonLabel).toBe('Sign up');
  });
  it('checks fields before sending', () => {
    const f = { email: 'a@b.co', firstName: '', lastName: '', phone: '', wantsSms: false };
    expect(signupProblem(f, { offerSms: true })).toBeNull();
    expect(signupProblem({ ...f, email: 'nope' }, { offerSms: false })).toMatch(/email/);
    expect(signupProblem({ ...f, wantsSms: true, phone: '12' }, { offerSms: true })).toMatch(/mobile/);
    expect(signupProblem({ ...f, wantsSms: true, phone: '(212) 555-0100' }, { offerSms: true })).toBeNull();
    expect(signupProblem({ ...f, wantsSms: true, phone: '12' }, { offerSms: false })).toBeNull();
  });
  it('reads only 64-hex tokens', () => {
    expect(signupToken(`?t=${'a'.repeat(64)}`)).toBe('a'.repeat(64));
    expect(signupToken('?t=abc')).toBeNull();
    expect(signupToken('')).toBeNull();
  });
});

describe('exos-signup body', () => {
  it('takes the form id from the path (ours or Opendate\'s) or the body', () => {
    expect(formIdFromPath(`/functions/v1/exos-signup/${FORM}`)).toBe(FORM);
    expect(formIdFromPath(`/exos-signup/forms/${FORM.toUpperCase()}/submissions`)).toBe(FORM);
    expect(formIdFromPath('/exos-signup')).toBeNull();
    expect(formIdFromPath('/exos-signup/../x')).toBeNull();
    expect(parseSignupBody({ form_id: FORM, email: 'a@b.co' }, null).formId).toBe(FORM);
    expect(() => parseSignupBody({ email: 'a@b.co' }, null)).toThrow(SignupInputError);
  });
  it('reads our names and Opendate\'s fan[...] wrapper', () => {
    const a = parseSignupBody({ fan: { email: ' a@b.co ', first_name: 'A', phone_number: '+12125550100', subscribe_to_marketing_sms: 'true' } }, FORM);
    expect(a).toMatchObject({ email: 'a@b.co', firstName: 'A', phone: '+12125550100', smsOptIn: true, emailOptIn: true, bot: false });
    expect(parseSignupBody({ email: 'a@b.co', subscribe_to_marketing_email: 'false' }, FORM).emailOptIn).toBe(false);
    expect(parseSignupBody({ email: 'a@b.co', subscribe_to_marketing_email: 'maybe' }, FORM).emailOptIn).toBe(true);
    expect(() => parseSignupBody({ email: 'a@b.co', first_name: 'x'.repeat(61) }, FORM)).toThrow(/at most 60/);
    expect(() => parseSignupBody({ email: 5 }, FORM)).toThrow(/text/);
    expect(() => parseSignupBody({}, FORM)).toThrow(/required/);
  });
  it('spots the honeypot and picks up a captcha token', () => {
    expect(parseSignupBody({ email: 'a@b.co', url: 'http://spam' }, FORM).bot).toBe(true);
    expect(parseSignupBody({ email: 'a@b.co', url: '' }, FORM).bot).toBe(false);
    expect(parseSignupBody({ email: 'a@b.co', 'cf-turnstile-response': 'tok' }, FORM).captchaToken).toBe('tok');
    expect(truthy('ON')).toBe(true);
    expect(truthy('nope')).toBe(false);
  });
});

describe('captcha hook', () => {
  it('is off without a secret', () => {
    expect(captchaConfig(() => undefined)).toBeNull();
    expect(captchaConfig((n) => (n === 'EXOS_SIGNUP_CAPTCHA_SECRET' ? ' s ' : undefined))).toEqual({ provider: 'turnstile', secret: 's' });
    expect(captchaConfig((n) => ({ EXOS_SIGNUP_CAPTCHA_SECRET: 's', EXOS_SIGNUP_CAPTCHA_PROVIDER: 'hCaptcha' } as Record<string, string>)[n])?.provider).toBe('hcaptcha');
  });
  it('builds the verify request and reads the answer', () => {
    const r = captchaVerifyRequest({ provider: 'turnstile', secret: 's&x' }, 'tok', '1.2.3.4');
    expect(r.url).toBe('https://challenges.cloudflare.com/turnstile/v0/siteverify');
    expect(new URLSearchParams(r.body).get('secret')).toBe('s&x');
    expect(new URLSearchParams(r.body).get('remoteip')).toBe('1.2.3.4');
    expect(new URLSearchParams(captchaVerifyRequest({ provider: 'hcaptcha', secret: 's' }, 't', 'unknown').body).has('remoteip')).toBe(false);
    expect(captchaPassed({ success: true })).toBe(true);
    expect(captchaPassed({ success: 'true' })).toBe(false);
    expect(captchaPassed(null)).toBe(false);
  });
});
