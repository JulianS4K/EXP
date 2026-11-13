// Spanish buyer mail (mig 20261114130000, docs/i18n-review.md):
// - SQL-built rows: _shared/mail-es.ts translates the fixed sentences of the
//   mails it knows, all or nothing (the fixtures are the English bodies the
//   SQL functions build today, data in <strong> as they put it);
// - payload rows: mail-templates.ts renders the Spanish version when the row's
//   lang is 'es' and the template has one, English otherwise.
import { describe, expect, it } from 'vitest';
import { leftoverText, localizeMailEs } from '../../supabase/functions/_shared/mail-es.ts';
import { renderTemplate, SPANISH_TEMPLATES, formatWhenEs } from '../../supabase/functions/_shared/mail-templates.ts';

const EVN = 'Noche &amp; Día';
const RECEIPT =
  '<p>Paid: <strong>45.00 USD</strong> (including 3.00 tax). Order reference: cs_test_123.</p>' +
  '<table style="border-collapse:collapse;font-size:14px"><tr><td style="padding:2px 12px 2px 0">2 &times; General Admission</td>' +
  '<td style="padding:2px 0;text-align:right">45.00</td></tr></table>' +
  '<p>Seats: A-1; A-2</p>' +
  '<p style="color:#666;font-size:13px">All-in price: the prices above include 4.00 service fee and tax; nothing was added at checkout.</p>' +
  '<p><a href="{{app_url}}/my-tickets">View your tickets</a></p>';

// [template, subject, html] as the SQL builds them.
const SQL_MAILS: [string, string, string][] = [
  ['ticket-issued (fulfil, paid)', `Your tickets for ${EVN} are ready`,
    `<p>Payment received — your 2 tickets for <strong>${EVN}</strong> are in your wallet. Open the app to show your QR at the door.</p>${RECEIPT}`],
  ['ticket-issued (fulfil, one, guest account)', `Your ticket for ${EVN} is ready`,
    `<p>Payment received — your 1 ticket for <strong>${EVN}</strong> is in your wallet. Sign in to Exos with this email to show your QR at the door.</p>` +
    '<p style="color:#666;font-size:13px">All-in price: no fees were added at checkout.</p>'],
  ['transfer-initiated (fulfil, claim links)', `Your tickets for ${EVN}`,
    `<p>Payment received. Your 2 tickets for <strong>${EVN}</strong> are waiting for you. Open a link below and sign in with a one-time code sent to this email (no password needed) to get your entry QR code. Send a link to a friend and they can claim that ticket themselves.</p>` +
    '<ul><li><a href="{{app_url}}/claim/abc?k=1">Claim ticket 1</a></li><li><a href="{{app_url}}/claim/def?k=2">Claim ticket 2</a></li></ul>'],
  ['transfer-initiated (free claim)', `Your ticket for ${EVN}`,
    `<p>You're in. Your 1 ticket for <strong>${EVN}</strong> is waiting for you. Open a link below and sign in with a one-time code sent to this email (no password needed) to get your entry QR code. Send a link to a friend and they can claim that ticket themselves.</p>` +
    '<ul><li><a href="{{app_url}}/claim/abc?k=1">Claim ticket 1</a></li></ul>'],
  ['ticket-issued (proof released)', `Your ticket for ${EVN} is ready`,
    `<p>Email confirmed. Your 1 ticket for <strong>${EVN}</strong> is in your Exos wallet. Open the app to show your QR at the door.</p>`],
  ['transfer-initiated (proof by code)', `Your tickets for ${EVN}`,
    `<p>Your tickets for <strong>${EVN}</strong> are ready. Open a link below and sign in (a one-time code, no password) to get your entry QR code. Send a link to a friend and they can claim that ticket themselves.</p>` +
    '<ul><li><a href="{{app_url}}/claim/x">Claim ticket 1</a></li></ul>'],
  ['order-failed (sold out)', `Your order for ${EVN} didn't go through`,
    `<p>Sorry, the tickets you picked for <strong>${EVN}</strong> sold out while you were paying, so your order didn't go through. Your payment is being refunded in full; it can take 5 to 10 days to show up.</p>`],
  ['order-failed (limit)', `Your order for ${EVN} didn't go through`,
    `<p>Sorry, the tickets you picked for <strong>${EVN}</strong> couldn't be issued because you already have as many tickets as this event allows per person, so this order didn't go through. Your payment is being refunded in full; it can take 5 to 10 days to show up.</p>`],
  ['ticket-issued (queue)', `Your ticket for ${EVN} is ready`,
    `<p>Your ticket (VIP) for <strong>${EVN}</strong> is in your wallet. Open the app to show your QR at the door.</p>`],
  ['ticket-issued (issued to email)', `Your ticket for ${EVN} is ready`,
    `<p>You've been issued a ticket for <strong>${EVN}</strong>. Open the app to show your QR at the door.</p>`],
  ['transfer-initiated (organizer sent)', `You've been sent a ticket for ${EVN}`,
    `<p>The organizer of <strong>${EVN}</strong> sent you 2 tickets. Sign in to Exos with any Exos account, or create one, to claim them.</p>` +
    '<ul><li><a href="{{app_url}}/claim/a?k=1">Claim ticket</a></li></ul>'],
  ['transfer-initiated (friend)', 'Someone sent you a ticket',
    '<p>Someone sent you a ticket on Exos.</p><p><a href="{{app_url}}/claim/a?k=b">Claim your ticket</a> and sign in with any Exos account, or create one.</p>' +
    '<p>Whoever claims the link first gets the ticket, so keep this email to yourself.</p>'],
  ['transfer-claimed', 'Your ticket transfer was claimed',
    "<p>Good news — someone claimed the ticket you transferred. The transfer is complete and the new owner's ticket is now active.</p>"],
  ['ticket-issued (door, account)', `Your ticket for ${EVN} is ready`,
    `<p>Thanks for buying at the door. Your tickets for <strong>${EVN}</strong> are in the Exos app. Show the QR at the door.</p>`],
  ['transfer-initiated (door, no account)', `Your ticket for ${EVN}`,
    `<p>Thanks for buying at the door of <strong>${EVN}</strong>. Sign in to Exos with this email, or create an account, to keep your tickets in the app.</p>` +
    '<ul><li><a href="{{app_url}}/claim/a?k=1">Claim ticket</a></li></ul>'],
];

describe('localizeMailEs (SQL-built buyer mail)', () => {
  for (const [name, subject, html] of SQL_MAILS) {
    it(`translates ${name} completely`, () => {
      const r = localizeMailEs(subject, html);
      expect(r, `${name}: leftover "${leftoverText(html)}"`).not.toBeNull();
      expect(r!.subject).not.toBe(subject);
      // The event name, links and the receipt's data are untouched.
      if (subject.includes(EVN)) expect(r!.subject).toContain(EVN);
      if (html.includes(EVN)) expect(r!.html).toContain(`<strong>${EVN}</strong>`);
      for (const href of html.match(/href="[^"]*"/g) ?? []) expect(r!.html).toContain(href);
    });
  }

  it('builds the Spanish receipt (REVIEW: money)', () => {
    const r = localizeMailEs(SQL_MAILS[0][1], SQL_MAILS[0][2])!;
    expect(r.subject).toBe(`Tus entradas para ${EVN} están listas`);
    expect(r.html).toContain('Pago recibido: tus 2 entradas para');
    expect(r.html).toContain('<p>Pagado: <strong>45.00 USD</strong> (incluye 3.00 de impuestos). Referencia del pedido: cs_test_123.</p>');
    expect(r.html).toContain('Precio final: los precios de arriba incluyen 4.00 service fee e impuestos; no se agregó nada al pagar.');
    expect(r.html).toContain('<p>Asientos: A-1; A-2</p>');
    expect(r.html).toContain('>Ver tus entradas</a>');
    expect(r.html).toContain('2 &times; General Admission');
  });

  it('sends English when any sentence is unknown (never half Spanish)', () => {
    expect(localizeMailEs(`Your ticket for ${EVN} is ready`,
      `<p>Payment received — your 1 ticket for <strong>${EVN}</strong> is in your wallet. A brand new sentence for you.</p>`)).toBeNull();
    expect(localizeMailEs('A subject we never wrote', '<p>Hola</p>')).toBeNull();
  });

  it("doesn't count English inside names as leftover", () => {
    const r = localizeMailEs('Your ticket for The Party Is Here is ready',
      '<p>You\'ve been issued a ticket for <strong>The Party Is Here</strong>. Open the app to show your QR at the door.</p>');
    expect(r?.subject).toBe('Tu entrada para The Party Is Here está lista');
  });
});

const APP = 'https://exos.example/bridge';
const EV = '11111111-1111-4111-8111-111111111111';
const ORG = '33333333-3333-4333-8333-333333333333';
const event = { id: EV, name: 'Fiesta <Uno>', starts_at: '2026-10-02T00:00:00+00:00', timezone: 'America/New_York',
  doors_at: '2026-10-01T23:00:00+00:00', venue_name: 'Salón', venue_location: 'Queens, NY', org_id: ORG, org_name: 'Org' };

describe('Spanish payload mail', () => {
  it('has Spanish versions of the buyer mails', () => {
    expect(SPANISH_TEMPLATES.sort()).toEqual(['event-cancelled', 'event-updated', 'post-event', 'refund-issued']);
  });

  it('renders the refund mail in Spanish when asked (REVIEW: money)', () => {
    const r = renderTemplate('refund-issued', { event, amount_cents: 1000, currency: 'usd', order_ref: 'cs_1', partial: false }, APP, 'es');
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.subject).toBe('Reembolso emitido: $10.00 por Fiesta <Uno>');
    expect(r.html).toContain('lang="es"');
    expect(r.html).toContain('Fiesta &lt;Uno&gt;');
    expect(r.html).toContain('de 5 a 10 días');
  });

  it('renders Spanish dates in the event zone', () => {
    expect(formatWhenEs('2026-10-02T00:00:00Z', 'America/New_York')).toMatch(/jueves.*1.*octubre/);
    const r = renderTemplate('event-updated', { event, marketing: false }, APP, 'es');
    expect(r.ok && r.html).toContain('Las puertas abren el');
  });

  it('keeps the unsubscribe link on Spanish marketing mail', () => {
    const r = renderTemplate('post-event', {
      event, org: { id: ORG, name: 'Org' }, following: false, marketing: true, unsubscribe_token: 'a'.repeat(64), next_events: [],
    }, APP, 'es');
    expect(r.ok && r.html).toContain(`${APP}/unsubscribe?t=${'a'.repeat(64)}`);
    expect(r.ok && r.html).toContain('Cancelar suscripción');
    expect(renderTemplate('post-event', { event, org: { id: ORG, name: 'Org' }, marketing: true }, APP, 'es').ok).toBe(false);
  });

  it('falls back to English for a template without Spanish, and by default', () => {
    const r = renderTemplate('event-published', { event, marketing: false }, APP, 'es');
    expect(r.ok && r.subject).toBe('Published: Fiesta <Uno>');
    const d = renderTemplate('refund-issued', { event, amount_cents: 1000, currency: 'usd', order_ref: 'cs_1' }, APP);
    expect(d.ok && d.subject).toBe('Refund issued: $10.00 for Fiesta <Uno>');
  });

  it('checks the payload the same way in Spanish', () => {
    expect(renderTemplate('refund-issued', { event: { ...event, id: 'nope' }, amount_cents: 1 }, APP, 'es').ok).toBe(false);
  });
});
