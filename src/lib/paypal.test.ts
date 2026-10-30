// PayPal / Venmo (mig 20261031220000): pricing parity with Stripe, the
// order body, ids and money, the write allowlist, webhook verification with
// fixtures, and the capture / webhook flows against a fake database. Every
// PayPal call goes to a fetch mock; nothing here reaches PayPal.
import { describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import { allInCents } from '../../supabase/functions/_shared/pricing.ts';
import { unitFeeTotals, type UnitFee } from '../../supabase/functions/_shared/fees.ts';
import { chargeTotalCents, stripeLineItems, type ChargeLine } from '../../supabase/functions/_shared/chargeLines.ts';
import {
  assertAllowed, createPayPalClient, paypalConfig, PayPalError, PAYPAL_HOSTS, type PayPalConfig,
} from '../../supabase/functions/_shared/paypal/client.ts';
import {
  approveUrl, captureFacts, captureIdFromRef, certUrlAllowed, disputeFacts, fromPayPalValue, newPayPalSessionId,
  orderCapture, paypalOrderBody, ppRef, refundFacts, refundStatus, toPayPalValue, verifyBody, webhookHeaders,
} from '../../supabase/functions/_shared/paypal/model.ts';
import { captureOrder, handleWebhook, refundPayPal, type Db } from '../../supabase/functions/_shared/paypal/flows.ts';
import { paypalTxn, reconcilePayPal } from '../../supabase/functions/_shared/paypal/reconcile.ts';
import { checkoutFeeSplit, PAYPAL_FEE, STRIPE_CARD_FEE } from '../../supabase/functions/_shared/platformFee.ts';
import { orderIdFromReturn, paypalSdkUrl, readPayPalCart, stashPayPalCart, venmoPossible } from './paypal';

const SESSION = 'pp_0123456789abcdef0123456789abcdef';
const CFG: PayPalConfig = { env: 'sandbox', baseUrl: PAYPAL_HOSTS.sandbox, clientId: 'cid', clientSecret: 'sec', webhookId: 'WH-123' };

// ── fetch mock ──────────────────────────────────────────────────────────────
type Route = (url: string, init: RequestInit) => { status?: number; body: unknown } | undefined;
function mockFetch(...routes: Route[]) {
  const calls: { url: string; method: string; headers: Record<string, string>; body: string | undefined }[] = [];
  const f = vi.fn(async (url: string, init: RequestInit = {}) => {
    calls.push({ url, method: String(init.method), headers: init.headers as Record<string, string>, body: init.body as string | undefined });
    if (url.endsWith('/v1/oauth2/token')) return new Response(JSON.stringify({ access_token: 'tok', expires_in: 3600 }), { status: 200 });
    for (const r of routes) {
      const out = r(url, init);
      if (out) return new Response(JSON.stringify(out.body), { status: out.status ?? 200 });
    }
    return new Response(JSON.stringify({ name: 'NOT_MOCKED' }), { status: 599 });
  });
  return { f, calls };
}

// A tier at $25.00, a $2.00 passed-on facility fee and 8.875% exclusive tax;
// an add-on at $10.00 with the same tax. What the storefront shows.
const FEES: UnitFee[] = [{ name: 'Facility fee', calc: 'fixed', amount_cents: 200 }];
function cart(qty: number, addonQty: number): { lines: ChargeLine[]; total: number } {
  const ticket = allInCents(2500, 8.875, FEES);
  const addon = allInCents(1000, 8.875, []);
  const lines: ChargeLine[] = [
    { name: 'Show — GA', unitCents: ticket, quantity: qty, description: `Includes ${unitFeeTotals(2500, FEES).total} fee` },
    { name: 'Show — Parking', unitCents: addon, quantity: addonQty },
    { name: 'Show — Free sticker', unitCents: 0, quantity: 1 },
  ];
  return { lines, total: ticket * qty + addon * addonQty };
}

describe('pricing parity: Stripe and PayPal charge the same', () => {
  it.each([[1, 0], [2, 1], [10, 3]])('%i tickets + %i add-ons', (qty, addons) => {
    const { lines, total } = cart(qty, addons);
    const stripe = stripeLineItems(lines, 'usd');
    const stripeTotal = stripe.reduce((n, l) => n + l.price_data.unit_amount * l.quantity, 0);
    const body = paypalOrderBody({ sessionId: SESSION, currency: 'usd', amountCents: total, lines });
    const unit = (body.purchase_units as Record<string, any>[])[0];
    const ppItems = (unit.items as { quantity: string; unit_amount: { value: string } }[])
      .reduce((n, i) => n + fromPayPalValue(i.unit_amount.value)! * Number(i.quantity), 0);
    expect(chargeTotalCents(lines)).toBe(total);
    expect(stripeTotal).toBe(total);
    expect(fromPayPalValue(unit.amount.value)).toBe(total);
    expect(fromPayPalValue(unit.amount.breakdown.item_total.value)).toBe(total);
    expect(ppItems).toBe(total);
    // Same paid lines on both sides (the $0 line on neither).
    expect(stripe.map((l) => [l.price_data.unit_amount, l.quantity]))
      .toEqual((unit.items as any[]).map((i) => [fromPayPalValue(i.unit_amount.value), Number(i.quantity)]));
    // No fee line: all-in.
    expect((unit.items as any[]).some((i) => /fee/i.test(i.name))).toBe(false);
  });

  it('refuses an order whose lines disagree with the total', () => {
    const { lines, total } = cart(2, 0);
    expect(() => paypalOrderBody({ sessionId: SESSION, currency: 'usd', amountCents: total + 1, lines })).toThrow();
    expect(() => paypalOrderBody({ sessionId: SESSION, currency: 'jpy', amountCents: total, lines })).toThrow();
  });

  it('records the same fee split shape, PayPal rate in the card slot', () => {
    const s = checkoutFeeSplit(4000, { bps: 300, card: PAYPAL_FEE });
    expect(s).toEqual({ applicationFeeCents: 120 + 189, exosFeeCents: 120, cardFeeEstCents: 189, feeBps: 300 });
    expect(checkoutFeeSplit(4000, { bps: 300, card: STRIPE_CARD_FEE }).exosFeeCents).toBe(s.exosFeeCents);
  });
});

describe('order body', () => {
  it('ties the order to the session and keeps names within PayPal limits', () => {
    const body = paypalOrderBody({
      sessionId: SESSION, currency: 'usd', amountCents: 1000,
      lines: [{ name: 'x'.repeat(300), unitCents: 1000, quantity: 1 }],
      returnUrl: 'https://exos.example/bridge/pay/paypal/return', cancelUrl: 'https://exos.example/bridge/event/1',
    });
    const unit = (body.purchase_units as any[])[0];
    expect(body.intent).toBe('CAPTURE');
    expect(unit.custom_id).toBe(SESSION);
    expect(unit.invoice_id).toBe(SESSION);
    expect(unit.items[0].name.length).toBe(127);
    expect((body.payment_source as any).paypal.experience_context.return_url).toContain('/pay/paypal/return');
    expect(paypalOrderBody({ sessionId: SESSION, currency: 'usd', amountCents: 1000, lines: [{ name: 'a', unitCents: 1000, quantity: 1 }] }).payment_source)
      .toBeUndefined();
  });

  it('reads the approve link only from PayPal', () => {
    expect(approveUrl({ links: [{ rel: 'payer-action', href: 'https://www.sandbox.paypal.com/checkoutnow?token=X' }] })).toContain('paypal.com');
    expect(approveUrl({ links: [{ rel: 'payer-action', href: 'https://evil.example/x' }] })).toBeNull();
  });
});

describe('money and ids', () => {
  it('converts cents exactly', () => {
    expect(toPayPalValue(0)).toBe('0.00');
    expect(toPayPalValue(5)).toBe('0.05');
    expect(toPayPalValue(123456)).toBe('1234.56');
    expect(fromPayPalValue('12.3')).toBe(1230);
    expect(fromPayPalValue('12')).toBe(1200);
    expect(fromPayPalValue('0.07')).toBe(7);
    for (const bad of ['-1.00', '1.234', '1e3', '', ' ', 'abc', 12 as unknown as string]) expect(fromPayPalValue(bad)).toBeNull();
    expect(() => toPayPalValue(1.5)).toThrow();
  });

  it('prefixes ledger ids so they never look like Stripe ones', () => {
    expect(ppRef.capture('3C679366HH908993F')).toBe('ppcap_3C679366HH908993F');
    expect(ppRef.dispute('PP-D-27803')).toBe('ppdsp_PPD27803');
    expect(captureIdFromRef('ppcap_3C679366HH908993F')).toBe('3C679366HH908993F');
    expect(captureIdFromRef('pi_123')).toBeNull();
    expect(() => ppRef.capture('bad id!')).toThrow();
    expect(newPayPalSessionId(() => '0123456789ABCDEF0123456789ABCDEF')).toBe(SESSION);
  });

  it('maps refund statuses', () => {
    expect(refundStatus('COMPLETED')).toBe('succeeded');
    expect(refundStatus('PENDING')).toBe('pending');
    expect(refundStatus('CANCELLED')).toBe('canceled');
    expect(refundStatus('FAILED')).toBe('failed');
  });
});

describe('the write allowlist', () => {
  it('allows only token, verify, order create, capture and refund POSTs', () => {
    for (const ok of ['/v1/oauth2/token', '/v1/notifications/verify-webhook-signature', '/v2/checkout/orders',
      '/v2/checkout/orders/5O190127TN364715T/capture', '/v2/payments/captures/3C679366HH908993F/refund']) {
      expect(() => assertAllowed('POST', ok)).not.toThrow();
    }
    for (const bad of ['/v1/payments/payouts', '/v2/checkout/orders/5O190127TN364715T/authorize', '/v1/vault/payment-tokens',
      '/v2/invoicing/invoices', '/v1/notifications/webhooks', '/v2/payments/authorizations/X/capture']) {
      expect(() => assertAllowed('POST', bad)).toThrow(/allowlist/);
    }
    for (const m of ['PUT', 'PATCH', 'DELETE']) expect(() => assertAllowed(m, '/v2/checkout/orders')).toThrow();
  });

  it('is sandbox unless EXOS_PAYPAL_ENV=live, and off without keys', () => {
    const env = (e: Record<string, string>) => (k: string) => e[k];
    expect(paypalConfig(env({}))).toBeNull();
    expect(paypalConfig(env({ PAYPAL_CLIENT_ID: 'a' }))).toBeNull();
    expect(paypalConfig(env({ PAYPAL_CLIENT_ID: 'a', PAYPAL_CLIENT_SECRET: 'b' }))!.baseUrl).toBe('https://api-m.sandbox.paypal.com');
    expect(paypalConfig(env({ PAYPAL_CLIENT_ID: 'a', PAYPAL_CLIENT_SECRET: 'b', EXOS_PAYPAL_ENV: 'production' }))!.env).toBe('sandbox');
    expect(paypalConfig(env({ PAYPAL_CLIENT_ID: 'a', PAYPAL_CLIENT_SECRET: 'b', EXOS_PAYPAL_ENV: 'live' }))!.baseUrl).toBe('https://api-m.paypal.com');
  });

  it('sends PayPal-Request-Id on writes and raises PayPal errors with their issues', async () => {
    const { f, calls } = mockFetch((url) => (url.endsWith('/capture')
      ? { status: 422, body: { name: 'UNPROCESSABLE_ENTITY', details: [{ issue: 'ORDER_ALREADY_CAPTURED' }] } } : undefined));
    const pp = createPayPalClient(CFG, f);
    const err = await pp.captureOrder('5O190127TN364715T', 'exos_cap_x').catch((e) => e);
    expect(err).toBeInstanceOf(PayPalError);
    expect(err.has('ORDER_ALREADY_CAPTURED')).toBe(true);
    expect(err.definitive).toBe(true);
    const cap = calls.find((c) => c.url.endsWith('/capture'))!;
    expect(cap.headers['PayPal-Request-Id']).toBe('exos_cap_x');
    expect(cap.url.startsWith('https://api-m.sandbox.paypal.com/')).toBe(true);
  });
});

// ── webhook fixtures ────────────────────────────────────────────────────────
const HEADERS: Record<string, string> = {
  'paypal-auth-algo': 'SHA256withRSA',
  'paypal-cert-url': 'https://api.sandbox.paypal.com/v1/notifications/certs/CERT-360caa42-fca2a594-1d93a270',
  'paypal-transmission-id': '69cd13f0-d67a-11e5-baa3-778b53f4ae55',
  'paypal-transmission-sig': 'lmI95Jx3Y9nhR5SJWlHVIWpg4AgFk7n9bCHSRxbrd8A9zrhdu2rMyFrmz+Zjh3s3boXB07VXCXUZy/UFzUlnGJn0wDugt7FlSvdKeIJenLRemUxYCPVoEZzg9VFNqOa48gMkvF+XTpxBeUx/kWy6B5cp7GkT2+pOowfRK7OaynuxUoKW3JcMWw272VKjLTtTAShncla7tGF+55rxyt2KNZIIqxNMJ48RDZheGU5w1npu9dZHnPgTXB9iomeVRoD8O/jhRpnKsGrDschyNdkeh81BJJMH4Ctc6lnCCquoP/GzCzz33MMsNdid7vL/NIWaCsekQpW26FpWPi/tfj8nLA==',
  'paypal-transmission-time': '2026-10-30T18:22:01Z',
};
const get = (h: Record<string, string>) => (k: string) => h[k.toLowerCase()] ?? null;

const CAPTURE_COMPLETED = JSON.stringify({
  id: 'WH-2WR32451HC0233532-67976317FL4543714',
  event_type: 'PAYMENT.CAPTURE.COMPLETED',
  resource: {
    id: '3C679366HH908993F',
    status: 'COMPLETED',
    amount: { currency_code: 'USD', value: '54.17' },
    custom_id: SESSION,
    invoice_id: SESSION,
    seller_receivable_breakdown: { gross_amount: { value: '54.17' }, paypal_fee: { value: '2.38' }, net_amount: { value: '51.79' } },
    supplementary_data: { related_ids: { order_id: '5O190127TN364715T' } },
  },
});

function fakeDb(rpcs: Record<string, (args: Record<string, unknown>) => { data?: unknown; error?: { code?: string; message?: string } }>, rows: Record<string, Record<string, unknown>[]> = {}) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const db: Db = {
    rpc: async (fn, args) => {
      calls.push({ fn, args });
      const h = rpcs[fn];
      if (!h) return { data: null, error: { message: `unexpected rpc ${fn}` } };
      const r = h(args);
      return { data: r.data ?? null, error: r.error ?? null };
    },
    rows: async (table) => rows[table] ?? [],
  };
  return { db, calls };
}

describe('webhook verification (fixtures)', () => {
  it('rejects missing or foreign transmission headers before calling PayPal', async () => {
    const { f, calls } = mockFetch();
    const pp = createPayPalClient(CFG, f);
    const { db } = fakeDb({});
    for (const h of [{}, { ...HEADERS, 'paypal-cert-url': 'https://evil.example/cert.pem' }, { ...HEADERS, 'paypal-auth-algo': 'none' }]) {
      const out = await handleWebhook(db, pp, get(h as Record<string, string>), CAPTURE_COMPLETED, true, () => undefined);
      expect(out.http).toBe(400);
    }
    expect(calls.length).toBe(0);
    expect(certUrlAllowed('https://api.paypal.com/v1/notifications/certs/X')).toBe(true);
    expect(certUrlAllowed('http://api.paypal.com/x')).toBe(false);
    expect(certUrlAllowed('https://api.paypal.com.evil.example/x')).toBe(false);
  });

  it('sends the raw event to verify-webhook-signature and refuses a FAILURE', async () => {
    const { f, calls } = mockFetch((url) => (url.endsWith('/verify-webhook-signature') ? { body: { verification_status: 'FAILURE' } } : undefined));
    const pp = createPayPalClient(CFG, f);
    const { db, calls: dbCalls } = fakeDb({});
    const out = await handleWebhook(db, pp, get(HEADERS), CAPTURE_COMPLETED, true, () => undefined);
    expect(out.http).toBe(400);
    expect(dbCalls.length).toBe(0);
    const v = calls.find((c) => c.url.endsWith('/verify-webhook-signature'))!;
    // The event goes in byte for byte, with our webhook id and PayPal's headers.
    expect(v.body).toBe(verifyBody(webhookHeaders(get(HEADERS))!, 'WH-123', CAPTURE_COMPLETED));
    expect(v.body!.endsWith(`"webhook_event":${CAPTURE_COMPLETED}}`)).toBe(true);
    expect(JSON.parse(v.body!).webhook_id).toBe('WH-123');
  });

  it('never splices a non-object body into the verify request', async () => {
    const { f, calls } = mockFetch(() => ({ body: { verification_status: 'SUCCESS' } }));
    const pp = createPayPalClient(CFG, f);
    const { db } = fakeDb({});
    const out = await handleWebhook(db, pp, get(HEADERS), '{"a":1},"webhook_id":"ATTACKER"', true, () => undefined);
    expect(out.http).toBe(400);
    expect(calls.some((c) => c.url.endsWith('/verify-webhook-signature'))).toBe(false);
  });

  it('a verified PAYMENT.CAPTURE.COMPLETED records the capture (and nothing else)', async () => {
    const { f } = mockFetch((url) => (url.endsWith('/verify-webhook-signature') ? { body: { verification_status: 'SUCCESS' } } : undefined));
    const pp = createPayPalClient(CFG, f);
    const { db, calls } = fakeDb({
      exos_paypal_record_capture: () => ({ data: { session_id: SESSION, session_status: 'fulfilled', payment_status: 'succeeded', needs_refund: false } }),
    });
    const out = await handleWebhook(db, pp, get(HEADERS), CAPTURE_COMPLETED, true, () => undefined);
    expect(out.http).toBe(200);
    expect(calls).toEqual([{ fn: 'exos_paypal_record_capture', args: {
      p_order_id: '5O190127TN364715T', p_capture_id: '3C679366HH908993F', p_status: 'COMPLETED',
      p_amount_cents: 5417, p_currency: 'usd', p_fee_cents: 238, p_funding_source: null,
      p_provider_event_id: 'WH-2WR32451HC0233532-67976317FL4543714',
    } }]);
  });

  it('a DB error is a 500 so PayPal retries; a misconfigured webhook id too', async () => {
    const { f } = mockFetch(() => ({ body: { verification_status: 'SUCCESS' } }));
    const pp = createPayPalClient(CFG, f);
    const { db } = fakeDb({ exos_paypal_record_capture: () => ({ error: { message: 'boom' } }) });
    expect((await handleWebhook(db, pp, get(HEADERS), CAPTURE_COMPLETED, true, () => undefined)).http).toBe(500);
    expect((await handleWebhook(db, pp, get(HEADERS), CAPTURE_COMPLETED, false, () => undefined)).http).toBe(500);
  });

  it('a refund webhook settles by the capture link and finalizes an Exos refund request', async () => {
    const reqId = '3f1b0c8e-5c3a-4c69-9a5e-0d6f3d6c2a11';
    const raw = JSON.stringify({ id: 'WH-R1', event_type: 'PAYMENT.CAPTURE.REFUNDED', resource: {
      id: '1JU08902781691411', status: 'COMPLETED', amount: { value: '54.17', currency_code: 'USD' }, custom_id: `exos_refund_${reqId}`,
      links: [{ rel: 'up', href: 'https://api.sandbox.paypal.com/v2/payments/captures/3C679366HH908993F' }],
    } });
    const { f } = mockFetch(() => ({ body: { verification_status: 'SUCCESS' } }));
    const pp = createPayPalClient(CFG, f);
    const { db, calls } = fakeDb({
      exos_record_refund: () => ({ data: 'r1' }),
      exos_refund_finalize: () => ({ data: { voided: 2 } }),
      exos_refund_checkout: () => ({ data: 2 }),
    }, {
      exos_order_payments: [{ session_id: SESSION }],
      exos_checkout_sessions: [{ amount_cents: 5417 }],
      exos_order_refunds: [{ amount_cents: 5417 }],
    });
    const out = await handleWebhook(db, pp, get(HEADERS), raw, true, () => undefined);
    expect(out.http).toBe(200);
    expect(calls.map((c) => c.fn)).toEqual(['exos_record_refund', 'exos_refund_finalize', 'exos_refund_checkout']);
    expect(calls[0].args).toMatchObject({ p_refund_id: 'pprf_1JU08902781691411', p_payment_intent: 'ppcap_3C679366HH908993F', p_status: 'succeeded' });
    expect(calls[1].args).toMatchObject({ p_request_id: reqId, p_stripe_refund_id: 'pprf_1JU08902781691411' });
  });

  it('a lost dispute voids the order', async () => {
    const raw = JSON.stringify({ id: 'WH-D1', event_type: 'CUSTOMER.DISPUTE.RESOLVED', resource: {
      dispute_id: 'PP-D-27803', status: 'RESOLVED', reason: 'MERCHANDISE_OR_SERVICE_NOT_RECEIVED',
      dispute_outcome: { outcome_code: 'RESOLVED_BUYER_FAVOUR' }, dispute_amount: { currency_code: 'USD', value: '54.17' },
      disputed_transactions: [{ seller_transaction_id: '3C679366HH908993F', buyer: { name: 'secret buyer' } }],
      messages: [{ content: 'private' }],
    } });
    const { f } = mockFetch(() => ({ body: { verification_status: 'SUCCESS' } }));
    const pp = createPayPalClient(CFG, f);
    const { db, calls } = fakeDb({
      exos_record_dispute_event: () => ({ data: 'lost' }),
      exos_refund_checkout: () => ({ data: 2 }),
    }, { exos_order_payments: [{ session_id: SESSION }] });
    expect((await handleWebhook(db, pp, get(HEADERS), raw, true, () => undefined)).http).toBe(200);
    expect(calls[0].args).toMatchObject({ p_dispute_id: 'ppdsp_PPD27803', p_status: 'lost', p_amount_cents: 5417, p_payment_intent: 'ppcap_3C679366HH908993F' });
    expect(JSON.stringify(calls[0].args.p_raw)).not.toContain('secret buyer');
    expect(JSON.stringify(calls[0].args.p_raw)).not.toContain('private');
    expect(calls[1].fn).toBe('exos_refund_checkout');
  });

  it('acknowledges events it does not handle', async () => {
    const { f } = mockFetch(() => ({ body: { verification_status: 'SUCCESS' } }));
    const pp = createPayPalClient(CFG, f);
    const { db, calls } = fakeDb({});
    const out = await handleWebhook(db, pp, get(HEADERS), JSON.stringify({ id: 'x', event_type: 'BILLING.PLAN.CREATED' }), true, () => undefined);
    expect(out.http).toBe(200);
    expect(calls.length).toBe(0);
  });
});

describe('dispute and capture facts', () => {
  it('maps PayPal dispute states onto the dispute row', () => {
    const base = { dispute_id: 'PP-D-1', disputed_transactions: [{ seller_transaction_id: '3C679366HH908993F' }] };
    expect(disputeFacts({ ...base, status: 'OPEN' })!.status).toBe('needs_response');
    expect(disputeFacts({ ...base, status: 'UNDER_REVIEW' })!.status).toBe('under_review');
    expect(disputeFacts({ ...base, status: 'RESOLVED', dispute_outcome: { outcome_code: 'RESOLVED_SELLER_FAVOUR' } })!.status).toBe('won');
    expect(disputeFacts({ ...base, status: 'RESOLVED', dispute_outcome: { outcome_code: 'ACCEPTED' } })!.status).toBe('lost');
    expect(disputeFacts({ dispute_id: '<script>' })).toBeNull();
  });

  it('reads the funding source and fee from a captured order', () => {
    const f = orderCapture({
      id: '5O190127TN364715T', status: 'COMPLETED', payment_source: { venmo: { email_address: 'x' } },
      purchase_units: [{ payments: { captures: [{ id: '3C679366HH908993F', status: 'COMPLETED', amount: { value: '20.00', currency_code: 'USD' },
        seller_receivable_breakdown: { paypal_fee: { value: '1.19' } }, custom_id: SESSION }] } }],
    })!;
    expect(f).toMatchObject({ orderId: '5O190127TN364715T', captureId: '3C679366HH908993F', amountCents: 2000, feeCents: 119, fundingSource: 'venmo', customId: SESSION });
    expect(captureFacts({ id: 'x', status: 'COMPLETED' })).toBeNull();
    expect(refundFacts({ id: '1JU08902781691411', amount: { value: '1.00', currency_code: 'USD' }, status: 'PENDING' })!.captureId).toBeNull();
  });
});

describe('capture flow', () => {
  const order = (status = 'COMPLETED') => ({
    id: '5O190127TN364715T', status, payment_source: { paypal: {} },
    purchase_units: [{ payments: { captures: [{ id: '3C679366HH908993F', status, amount: { value: '40.00', currency_code: 'USD' },
      seller_receivable_breakdown: { paypal_fee: { value: '1.89' } }, custom_id: SESSION }] } }],
  });

  it('gates, captures once (request id per session) and fulfils', async () => {
    const { f, calls } = mockFetch((url, init) => (url.endsWith('/capture') && init.method === 'POST' ? { status: 201, body: order() } : undefined));
    const pp = createPayPalClient(CFG, f);
    const { db } = fakeDb({
      exos_paypal_capture_gate: () => ({ data: { ok: true, session_id: SESSION, status: 'pending' } }),
      exos_paypal_record_capture: () => ({ data: { session_id: SESSION, session_status: 'fulfilled', payment_status: 'succeeded', needs_refund: false } }),
    });
    const out = await captureOrder(db, pp, '5O190127TN364715T', () => undefined);
    expect(out).toEqual({ http: 200, body: { status: 'fulfilled', payment_status: 'succeeded', session_id: SESSION } });
    expect(calls.find((c) => c.url.endsWith('/capture'))!.headers['PayPal-Request-Id']).toBe(`exos_cap_${SESSION}`);
  });

  it("doesn't capture once the hold lapsed", async () => {
    const { f, calls } = mockFetch();
    const pp = createPayPalClient(CFG, f);
    const { db } = fakeDb({ exos_paypal_capture_gate: () => ({ data: { ok: false, session_id: SESSION, status: 'expired', reason: 'hold_expired' } }) });
    const out = await captureOrder(db, pp, '5O190127TN364715T', () => undefined);
    expect(out.http).toBe(409);
    expect(calls.length).toBe(0);
  });

  it('reads the order when PayPal says it was already captured', async () => {
    const { f } = mockFetch(
      (url, init) => (url.endsWith('/capture') && init.method === 'POST'
        ? { status: 422, body: { name: 'UNPROCESSABLE_ENTITY', details: [{ issue: 'ORDER_ALREADY_CAPTURED' }] } } : undefined),
      (url, init) => (url.endsWith('/v2/checkout/orders/5O190127TN364715T') && init.method === 'GET' ? { body: order() } : undefined),
    );
    const pp = createPayPalClient(CFG, f);
    const { db, calls } = fakeDb({
      exos_paypal_capture_gate: () => ({ data: { ok: true, session_id: SESSION, status: 'pending' } }),
      exos_paypal_record_capture: () => ({ data: { session_id: SESSION, session_status: 'fulfilled', payment_status: 'succeeded' } }),
    });
    expect((await captureOrder(db, pp, '5O190127TN364715T', () => undefined)).http).toBe(200);
    expect(calls.map((c) => c.fn)).toEqual(['exos_paypal_capture_gate', 'exos_paypal_record_capture']);
  });

  it('refunds in full, once, when the order can no longer be issued', async () => {
    const { f, calls } = mockFetch(
      (url, init) => (url.endsWith('/capture') && init.method === 'POST' ? { status: 201, body: order() } : undefined),
      (url) => (url.endsWith('/refund') ? { status: 201, body: { id: '1JU08902781691411', status: 'COMPLETED', amount: { value: '40.00', currency_code: 'USD' } } } : undefined),
    );
    const pp = createPayPalClient(CFG, f);
    const { db, calls: dbCalls } = fakeDb({
      exos_paypal_capture_gate: () => ({ data: { ok: true, session_id: SESSION, status: 'pending' } }),
      exos_paypal_record_capture: () => ({ data: { session_id: SESSION, session_status: 'failed', payment_status: 'succeeded', needs_refund: true } }),
      exos_record_refund: () => ({ data: 'r' }),
    });
    await captureOrder(db, pp, '5O190127TN364715T', () => undefined);
    const rf = calls.find((c) => c.url.endsWith('/refund'))!;
    expect(rf.headers['PayPal-Request-Id']).toBe(`exos_auto_refund_${SESSION}`);
    expect(JSON.parse(rf.body!).amount).toBeUndefined(); // the whole capture
    expect(dbCalls.at(-1)).toMatchObject({ fn: 'exos_record_refund', args: { p_refund_id: 'pprf_1JU08902781691411', p_amount_cents: 4000, p_status: 'succeeded' } });
  });

  it('a declined instrument asks the buyer to pick another', async () => {
    const { f } = mockFetch((url) => (url.endsWith('/capture') ? { status: 422, body: { details: [{ issue: 'INSTRUMENT_DECLINED' }] } } : undefined));
    const pp = createPayPalClient(CFG, f);
    const { db } = fakeDb({ exos_paypal_capture_gate: () => ({ data: { ok: true, session_id: SESSION, status: 'pending' } }) });
    const out = await captureOrder(db, pp, '5O190127TN364715T', () => undefined);
    expect(out.http).toBe(402);
    expect(out.body.retry).toBe(true);
  });
});

describe('organizer refunds route to PayPal', () => {
  it('refunds the claimed amount on the capture, keyed on the request', async () => {
    const { f, calls } = mockFetch((url) => (url.endsWith('/refund')
      ? { status: 201, body: { id: '1JU08902781691411', status: 'PENDING', amount: { value: '10.00', currency_code: 'USD' } } } : undefined));
    const pp = createPayPalClient(CFG, f);
    const rf = await refundPayPal(pp, { request_id: '3f1b0c8e-5c3a-4c69-9a5e-0d6f3d6c2a11', amount_cents: 1000, payment_intent: 'ppcap_3C679366HH908993F', session_id: SESSION, currency: 'usd' });
    expect(rf).toMatchObject({ ref: 'pprf_1JU08902781691411', status: 'pending', amountCents: 1000 });
    const c = calls.find((x) => x.url.endsWith('/refund'))!;
    expect(c.url).toContain('/v2/payments/captures/3C679366HH908993F/refund');
    expect(c.headers['PayPal-Request-Id']).toBe('exos_refund_3f1b0c8e-5c3a-4c69-9a5e-0d6f3d6c2a11');
    expect(JSON.parse(c.body!)).toMatchObject({ amount: { value: '10.00', currency_code: 'USD' }, custom_id: 'exos_refund_3f1b0c8e-5c3a-4c69-9a5e-0d6f3d6c2a11' });
    await expect(refundPayPal(pp, { request_id: 'x', amount_cents: 1, payment_intent: 'pi_123', session_id: 'cs_1', currency: 'usd' })).rejects.toThrow();
  });
});

describe('PayPal reconciliation report', () => {
  const t = (id: string, value: string, invoice = SESSION) => paypalTxn({ transaction_info: {
    transaction_id: id, transaction_event_code: value.startsWith('-') ? 'T1107' : 'T0006', transaction_status: 'S',
    transaction_amount: { value, currency_code: 'USD' }, fee_amount: { value: '-1.19' }, invoice_id: invoice,
    transaction_initiation_date: '2026-10-29T10:00:00+0000',
  } })!;
  const win = { from: '2026-10-28T00:00:00Z', to: '2026-10-30T00:00:00Z' };

  it('finds missing rows and amount differences both ways', () => {
    const r = reconcilePayPal(
      [t('CAPA00000001', '20.00'), t('CAPB00000002', '30.00'), t('RFA000000001', '-5.00'), t('OTHER0000001', '9.00', 'INV-NOT-OURS')],
      [
        { session_id: SESSION, payment_intent: 'ppcap_CAPA00000001', amount_cents: 2000, currency: 'usd', status: 'succeeded', created_at: '2026-10-29T10:00:00Z' },
        { session_id: SESSION, payment_intent: 'ppcap_CAPC00000003', amount_cents: 1000, currency: 'usd', status: 'succeeded', created_at: '2026-10-29T11:00:00+00:00' },
      ],
      [{ session_id: SESSION, refund_id: 'pprf_RFA000000001', amount_cents: 400, currency: 'usd', status: 'succeeded', created_at: '2026-10-29T12:00:00Z' }],
      win,
    );
    expect(r.issues.map((i) => [i.kind, i.key]).sort()).toEqual([
      ['exos_payment_missing', 'ppcap_CAPC00000003'],
      ['paypal_payment_missing', 'ppcap_CAPB00000002'],
      ['refund_amount_mismatch', 'pprf_RFA000000001'],
    ]);
    expect(r.checked.other).toBe(1);
  });

  it('is clean when everything matches', () => {
    const r = reconcilePayPal([t('CAPA00000001', '20.00')],
      [{ session_id: SESSION, payment_intent: 'ppcap_CAPA00000001', amount_cents: 2000, currency: 'usd', status: 'succeeded', created_at: '2026-10-29T10:00:00Z' }],
      [], win);
    expect(r.issues).toEqual([]);
  });
});

describe('the SPA side', () => {
  it('builds the SDK URL with Venmo on and cards off', () => {
    const u = new URL(paypalSdkUrl('AbCdEf123456', 'usd'));
    expect(u.origin).toBe('https://www.paypal.com');
    expect(u.searchParams.get('enable-funding')).toBe('venmo');
    expect(u.searchParams.get('disable-funding')).toContain('card');
    expect(u.searchParams.get('currency')).toBe('USD');
    expect(venmoPossible('usd')).toBe(true);
    expect(venmoPossible('eur')).toBe(false);
  });

  it('reads the order id from PayPal\'s return', () => {
    expect(orderIdFromReturn('?token=5O190127TN364715T&PayerID=X')).toBe('5O190127TN364715T');
    expect(orderIdFromReturn('?token=<x>')).toBeNull();
  });

  it('keeps the cart for an hour at most', () => {
    const store = new Map<string, string>();
    vi.stubGlobal('sessionStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v) });
    stashPayPalCart({ eventId: 'e', tierId: 't', quantity: 2, title: 'Show', currency: 'usd', at: 1_000 });
    expect(readPayPalCart(2_000)?.quantity).toBe(2);
    expect(readPayPalCart(1_000 + 3_600_001)).toBeNull();
    vi.unstubAllGlobals();
  });
});
