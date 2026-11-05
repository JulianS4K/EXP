// Signup-form submissions (exos-signup, mig 20261031120000). docs/fans.md.
//
// Pure helpers shared by the edge function and vitest (src/lib/signupForms.test.ts):
// reading a submission body (JSON or form-encoded, Opendate's field names
// accepted), the form id from the path, and the optional captcha check.
// No Deno or Supabase imports.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface SignupInput {
  formId: string;
  email: string;
  firstName: string | null;
  lastName: string | null;
  phone: string | null;
  emailOptIn: boolean;
  smsOptIn: boolean;
  /** The honeypot field was filled: answer as usual, write nothing. */
  bot: boolean;
  captchaToken: string | null;
}

export class SignupInputError extends Error {}

/** true / "true" / "1" / "on" / "yes". */
export function truthy(v: unknown): boolean {
  if (v === true || v === 1) return true;
  return typeof v === 'string' && ['true', '1', 'on', 'yes'].includes(v.trim().toLowerCase());
}

/** false / "false" / "0" / "off" / "no" (an explicit no; absent is neither). */
function falsy(v: unknown): boolean {
  if (v === false || v === 0) return true;
  return typeof v === 'string' && ['false', '0', 'off', 'no'].includes(v.trim().toLowerCase());
}

/**
 * The form id from the function-relative path: /<uuid>, /forms/<uuid>/submissions
 * (Opendate's embed contract), or null (then the body's form_id is used).
 */
export function formIdFromPath(urlPath: string): string | null {
  const p = urlPath.replace(/^.*?\/exos-signup(?=\/|$)/, '').replace(/\/+$/, '');
  const m = /^\/(?:forms\/)?([0-9a-f-]{36})(?:\/submissions)?$/i.exec(p);
  return m && UUID_RE.test(m[1]) ? m[1].toLowerCase() : null;
}

function text(v: unknown, max: number, name: string): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== 'string') throw new SignupInputError(`${name} must be text.`);
  const t = v.trim();
  if (t.length > max) throw new SignupInputError(`${name} is at most ${max} characters.`);
  return t || null;
}

/**
 * A submission body as SignupInput. Accepts our names and Opendate's
 * (fan[...] wrapped or bare): email, first_name, last_name, phone /
 * phone_number, subscribe_to_marketing_email, subscribe_to_marketing_sms,
 * url (honeypot), captcha_token / cf-turnstile-response / h-captcha-response.
 * Email defaults to yes (it is an email signup form) unless explicitly no.
 */
export function parseSignupBody(raw: Record<string, unknown>, pathFormId: string | null): SignupInput {
  const inner = raw.fan && typeof raw.fan === 'object' && !Array.isArray(raw.fan) ? raw.fan as Record<string, unknown> : raw;
  const b: Record<string, unknown> = { ...raw, ...inner };
  const formRaw = pathFormId ?? b.form_id ?? b.signup_form_id ?? null;
  if (typeof formRaw !== 'string' || !UUID_RE.test(formRaw)) throw new SignupInputError('form_id must be a signup form id.');
  const email = text(b.email, 254, 'email');
  if (!email) throw new SignupInputError('email is required.');
  const emailFlag = b.subscribe_to_marketing_email ?? b.email_opt_in;
  const smsFlag = b.subscribe_to_marketing_sms ?? b.sms_opt_in;
  const honeypot = b.url;
  const captcha = b.captcha_token ?? b['cf-turnstile-response'] ?? b['h-captcha-response'] ?? null;
  return {
    formId: formRaw.toLowerCase(),
    email,
    firstName: text(b.first_name, 60, 'first_name'),
    lastName: text(b.last_name, 60, 'last_name'),
    phone: text(b.phone ?? b.phone_number, 32, 'phone'),
    emailOptIn: !falsy(emailFlag),
    smsOptIn: truthy(smsFlag),
    bot: typeof honeypot === 'string' ? honeypot.trim() !== '' : honeypot !== undefined && honeypot !== null && honeypot !== '',
    captchaToken: typeof captcha === 'string' && captcha.trim() ? captcha.trim().slice(0, 4096) : null,
  };
}

// ── captcha hook ────────────────────────────────────────────────────────────
// Off unless EXOS_SIGNUP_CAPTCHA_SECRET is set. Provider: turnstile (default)
// or hcaptcha. Both verify the same way: POST secret + response (+ remoteip)
// form-encoded to the provider's siteverify, read { success }. The embed shows
// the widget when the SPA has VITE_EXOS_CAPTCHA_SITE_KEY.

export type CaptchaProvider = 'turnstile' | 'hcaptcha';

export interface CaptchaConfig {
  provider: CaptchaProvider;
  secret: string;
}

export const CAPTCHA_VERIFY_URL: Record<CaptchaProvider, string> = {
  turnstile: 'https://challenges.cloudflare.com/turnstile/v0/siteverify',
  hcaptcha: 'https://api.hcaptcha.com/siteverify',
};

export function captchaConfig(get: (name: string) => string | undefined): CaptchaConfig | null {
  const secret = (get('EXOS_SIGNUP_CAPTCHA_SECRET') ?? '').trim();
  if (!secret) return null;
  const p = (get('EXOS_SIGNUP_CAPTCHA_PROVIDER') ?? 'turnstile').trim().toLowerCase();
  return { provider: p === 'hcaptcha' ? 'hcaptcha' : 'turnstile', secret };
}

/** The siteverify request for a token (no network here). */
export function captchaVerifyRequest(cfg: CaptchaConfig, token: string, ip: string | null): { url: string; body: string } {
  const form = new URLSearchParams({ secret: cfg.secret, response: token });
  if (ip && ip !== 'unknown') form.set('remoteip', ip);
  return { url: CAPTCHA_VERIFY_URL[cfg.provider], body: form.toString() };
}

/** Whether the provider's answer is a pass. */
export function captchaPassed(answer: unknown): boolean {
  return !!answer && typeof answer === 'object' && (answer as { success?: unknown }).success === true;
}
