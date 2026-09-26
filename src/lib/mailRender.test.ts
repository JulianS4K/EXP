// exos-mail-drain's last-mile render (supabase/functions/_shared/mail-render.ts).
import { describe, it, expect } from 'vitest';
import { normalizeAppUrl, renderMail } from '../../supabase/functions/_shared/mail-render.ts';

describe('normalizeAppUrl', () => {
  it('accepts https (and http on localhost) and drops trailing slashes', () => {
    expect(normalizeAppUrl('https://exos.example/bridge/')).toBe('https://exos.example/bridge');
    expect(normalizeAppUrl(' https://exos.example ')).toBe('https://exos.example');
    expect(normalizeAppUrl('http://localhost:5173')).toBe('http://localhost:5173');
  });
  it('rejects unset, plain http, credentials, query strings and junk', () => {
    expect(normalizeAppUrl(undefined)).toBeNull();
    expect(normalizeAppUrl('')).toBeNull();
    expect(normalizeAppUrl('http://exos.example')).toBeNull();
    expect(normalizeAppUrl('https://u:p@exos.example')).toBeNull();
    expect(normalizeAppUrl('https://exos.example/?x=1')).toBeNull();
    expect(normalizeAppUrl('not a url')).toBeNull();
  });
});

describe('renderMail', () => {
  const html = '<a href="{{app_url}}/checkout?event=e">Finish</a> <a href="{{app_url}}/unsubscribe?t=abc">Unsubscribe</a>';

  it('fills every placeholder and sets List-Unsubscribe', () => {
    const r = renderMail(html, '{{app_url}}/unsubscribe?t=abc', 'https://exos.example/bridge');
    expect(r).toEqual({
      ok: true,
      html: '<a href="https://exos.example/bridge/checkout?event=e">Finish</a> <a href="https://exos.example/bridge/unsubscribe?t=abc">Unsubscribe</a>',
      headers: { 'List-Unsubscribe': '<https://exos.example/bridge/unsubscribe?t=abc>' },
    });
  });

  it('holds back a mail that links into the app when the URL is unset', () => {
    expect(renderMail(html, null, null).ok).toBe(false);
    expect(renderMail('<p>hi</p>', '{{app_url}}/unsubscribe?t=abc', null).ok).toBe(false);
  });

  it('passes ordinary mail through untouched, with no headers', () => {
    expect(renderMail('<p>Your ticket</p>', null, null)).toEqual({ ok: true, html: '<p>Your ticket</p>', headers: {} });
  });

  it('never emits a List-Unsubscribe header that is not an absolute URL', () => {
    const r = renderMail('<p>x</p>', 'javascript:alert(1)', 'https://exos.example');
    expect(r.ok && r.headers).toEqual({});
  });
});
