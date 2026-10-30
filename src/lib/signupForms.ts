// Signup forms (mig 20261031120000, docs/fans.md): the organizer builds a
// form, pastes a snippet on their site, fans sign up there. Email is double
// opt-in (the confirm mail's link), texts are confirmed signed in.
//
// Pure helpers (snippets, wording, parsing) up top; the calls below.

import { supabase } from './supabase';
import { consentText as smsConsentText } from './sms';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN_RE = /^[0-9a-f]{64}$/;

/** What the fan agrees to for email; the SQL stores the same words (exos_signup_email_consent_text). */
export function emailConsentText(orgName: string): string {
  return `Email me news and events from ${orgName}. I can unsubscribe at any time.`;
}
export { smsConsentText };

export interface SignupForm {
  id: string;
  name: string;
  title: string;
  intro: string | null;
  buttonLabel: string | null;
  askName: boolean;
  offerSms: boolean;
  defaultTagIds: string[];
  status: 'active' | 'paused' | 'archived';
  submissions: number;
  confirmed: number;
  createdAt: Date | null;
}

export interface PublicSignupForm {
  id: string;
  orgName: string;
  title: string;
  intro: string | null;
  buttonLabel: string;
  askName: boolean;
  offerSms: boolean;
  emailConsentText: string;
  smsConsentText: string | null;
}

const date = (v: unknown): Date | null => {
  if (!v) return null;
  const d = new Date(String(v));
  return Number.isNaN(d.getTime()) ? null : d;
};

export function parseSignupForm(r: any): SignupForm {
  const status = r?.status === 'paused' || r?.status === 'archived' ? r.status : 'active';
  return {
    id: String(r?.id ?? ''),
    name: String(r?.name ?? ''),
    title: String(r?.title ?? ''),
    intro: r?.intro ?? null,
    buttonLabel: r?.button_label ?? null,
    askName: r?.ask_name !== false,
    offerSms: r?.offer_sms === true,
    defaultTagIds: Array.isArray(r?.default_tag_ids) ? r.default_tag_ids.map(String) : [],
    status,
    submissions: Number(r?.submissions) || 0,
    confirmed: Number(r?.confirmed) || 0,
    createdAt: date(r?.created_at),
  };
}

export function parsePublicForm(r: any): PublicSignupForm | null {
  if (!r || typeof r !== 'object' || !r.id || !r.title) return null;
  return {
    id: String(r.id),
    orgName: String(r.org_name ?? ''),
    title: String(r.title),
    intro: r.intro ?? null,
    buttonLabel: String(r.button_label || 'Sign up'),
    askName: r.ask_name !== false,
    offerSms: r.offer_sms === true && typeof r.sms_consent_text === 'string',
    emailConsentText: String(r.email_consent_text ?? ''),
    smsConsentText: typeof r.sms_consent_text === 'string' ? r.sms_consent_text : null,
  };
}

/**
 * The paste-ready snippets for a form. `appBase` is the Exos app URL
 * ("https://host/bridge"). The script version sizes itself (public/embed.js);
 * the iframe works where scripts aren't allowed.
 */
export function signupSnippets(appBase: string, formId: string, title?: string): { script: string; iframe: string; link: string } {
  const base = appBase.replace(/\/+$/, '').replace(/"/g, '%22');
  const id = UUID_RE.test(formId) ? formId.toLowerCase() : 'FORM_ID';
  // The label goes in an HTML comment / attribute: strip what could break out.
  const label = (title ?? '').replace(/-{2,}/g, '—').replace(/[<>"]/g, '').slice(0, 120).trim();
  const link = `${base}/embed/signup/${id}`;
  return {
    script: `<!-- Exos signup form${label ? ` — ${label}` : ''} -->
<div data-exos-signup="${id}"></div>
<script src="${base}/embed.js" async></script>`,
    iframe: `<iframe src="${link}" title="${label || 'Sign up'}" style="width:100%;max-width:480px;height:460px;border:0" loading="lazy"></iframe>`,
    link,
  };
}

export interface SignupFields {
  email: string;
  firstName: string;
  lastName: string;
  phone: string;
  wantsSms: boolean;
}

/** Client-side check before sending (the server checks again). null = fine. */
export function signupProblem(f: SignupFields, form: Pick<PublicSignupForm, 'offerSms'>): string | null {
  const email = f.email.trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 254) return 'Enter a valid email address.';
  if (f.firstName.trim().length > 60 || f.lastName.trim().length > 60) return 'Names are at most 60 characters.';
  if (form.offerSms && f.wantsSms) {
    const s = f.phone.replace(/[^0-9+]/g, '');
    if (!/^\+[1-9][0-9]{7,14}$/.test(s) && !/^1?[2-9][0-9]{9}$/.test(s)) return 'Enter a mobile number, e.g. +1 212 555 0100.';
  }
  return null;
}

/** The ?t= token on /signup/confirm and /signup/unsubscribe, or null. */
export function signupToken(search: string): string | null {
  const t = new URLSearchParams(search).get('t') ?? '';
  return TOKEN_RE.test(t) ? t : null;
}

// ── calls ──────────────────────────────────────────────────────────────────

const msg = (e: { message?: string }) => new Error((e.message ?? 'Failed.').replace(/^exos_\w+: /, ''));

export async function listSignupForms(orgId: string): Promise<SignupForm[]> {
  const { data, error } = await supabase.rpc('exos_signup_forms_list', { p_org_id: orgId });
  if (error) throw msg(error);
  return (Array.isArray(data) ? data : []).map(parseSignupForm);
}

export async function saveSignupForm(orgId: string, formId: string | null, fields: Record<string, unknown>): Promise<string> {
  const { data, error } = await supabase.rpc('exos_signup_form_save', { p_org_id: orgId, p_form_id: formId, p_fields: fields });
  if (error) throw msg(error);
  return String(data);
}

export async function getPublicSignupForm(formId: string): Promise<PublicSignupForm | null> {
  if (!UUID_RE.test(formId)) return null;
  const { data, error } = await supabase.rpc('exos_signup_form_public', { p_form_id: formId });
  if (error) throw msg(error);
  return parsePublicForm(data);
}

/** Send a submission to exos-signup. Answers the same whatever the address. */
export async function submitSignup(formId: string, f: SignupFields, captchaToken: string | null, honeypot: string): Promise<void> {
  const { data, error } = await supabase.functions.invoke('exos-signup', {
    body: {
      form_id: formId, email: f.email.trim(), first_name: f.firstName.trim() || null, last_name: f.lastName.trim() || null,
      phone: f.wantsSms ? f.phone.trim() : null, subscribe_to_marketing_email: true,
      subscribe_to_marketing_sms: f.wantsSms, url: honeypot, captcha_token: captchaToken,
    },
  });
  if (error) {
    let text = 'Signup failed. Try again in a minute.';
    try {
      const body = await (error as { context?: Response }).context?.json();
      if (body?.error) text = String(body.error);
    } catch { /* keep the default */ }
    throw new Error(text);
  }
  if (!data?.ok) throw new Error('Signup failed. Try again in a minute.');
}

export async function confirmSignup(token: string): Promise<{ ok: boolean; orgName: string; already: boolean; smsPending: boolean }> {
  const { data, error } = await supabase.rpc('exos_signup_confirm', { p_token: token });
  if (error) throw msg(error);
  return { ok: data?.ok === true, orgName: String(data?.org_name ?? ''), already: data?.already === true, smsPending: data?.sms_pending === true };
}

export async function confirmSignupSms(token: string): Promise<string> {
  const { data, error } = await supabase.rpc('exos_signup_confirm_sms', { p_token: token });
  if (error) throw msg(error);
  return String(data?.phone_hint ?? '');
}

export async function unsubscribeSignup(token: string): Promise<{ ok: boolean; orgName: string }> {
  const { data, error } = await supabase.rpc('exos_signup_unsubscribe', { p_token: token });
  if (error) throw msg(error);
  return { ok: data?.ok === true, orgName: String(data?.org_name ?? '') };
}
