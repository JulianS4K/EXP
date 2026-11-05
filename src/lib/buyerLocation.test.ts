// Buyer location (mig 20261106140000): Stripe / PayPal payloads -> the four
// fields Exos keeps. Fixtures follow the shapes Stripe (API 2024-06-20) and
// PayPal Orders v2 send; a street line must never come through.
import { describe, expect, it, vi } from 'vitest';
import {
  cleanCountry, cleanPart, cleanPostal, locationFromPayPalOrder, locationFromStripeCharge, locationFromStripeSession,
  locationRpcArgs, recordBuyerLocation,
} from '../../supabase/functions/_shared/buyerLocation.ts';
import { recordFeeActuals, type ChargeLike, type FeeDb, type FeeStripe } from '../../supabase/functions/_shared/feeActuals.ts';
import { createPayPalClient, PAYPAL_HOSTS, type PayPalConfig } from '../../supabase/functions/_shared/paypal/client.ts';
import { captureOrder, type Db } from '../../supabase/functions/_shared/paypal/flows.ts';

const STREET = '742 Evergreen Terrace';

// checkout.session.completed data.object (trimmed to the parts we read).
const SESSION = {
  id: 'cs_test_a1b2c3',
  object: 'checkout.session',
  amount_total: 5417,
  currency: 'usd',
  payment_status: 'paid',
  status: 'complete',
  customer_details: {
    address: { city: 'Brooklyn', country: 'US', line1: STREET, line2: 'Apt 4', postal_code: '11211', state: 'NY' },
    email: 'buyer@example.com',
    name: 'Ada Buyer',
    phone: null,
    tax_exempt: 'none',
    tax_ids: [],
  },
  payment_intent: 'pi_3PqXyZ',
};

// A PaymentIntent's latest_charge (as the fee read expands it).
const CHARGE = {
  id: 'ch_3PqXyZ',
  object: 'charge',
  amount: 5417,
  application_fee_amount: 417,
  balance_transaction: { id: 'txn_1', fee: 187, net: 5230 },
  billing_details: {
    address: { city: 'Toronto', country: 'CA', line1: STREET, line2: null, postal_code: 'M5V 2T6', state: 'ON' },
    email: null, name: 'Ada Buyer', phone: null,
  },
  payment_method_details: { type: 'card', card: { brand: 'visa', country: 'GB', last4: '4242', exp_month: 12, exp_year: 2030 } },
};

// POST /v2/checkout/orders/:id/capture response (PayPal wallet).
const PAYPAL_CAPTURED = {
  id: '5O190127TN364715T',
  status: 'COMPLETED',
  payment_source: {
    paypal: {
      name: { given_name: 'John', surname: 'Doe' },
      email_address: 'customer@example.com',
      account_id: 'QYR5Z8XDVJNXQ',
      address: { address_line_1: STREET, admin_area_2: 'San Jose', admin_area_1: 'CA', postal_code: '95131', country_code: 'US' },
    },
  },
  payer: {
    name: { given_name: 'John', surname: 'Doe' },
    email_address: 'customer@example.com',
    payer_id: 'QYR5Z8XDVJNXQ',
    address: { country_code: 'US' },
  },
  purchase_units: [{
    reference_id: 'default',
    shipping: { address: { address_line_1: '1 Main St', admin_area_2: 'Austin', admin_area_1: 'TX', postal_code: '78701', country_code: 'US' } },
    payments: { captures: [{
      id: '3C679366HH908993F', status: 'COMPLETED', amount: { currency_code: 'USD', value: '54.17' },
      custom_id: 'pp_0123456789abcdef0123456789abcdef',
      seller_receivable_breakdown: { gross_amount: { value: '54.17' }, paypal_fee: { value: '2.38' }, net_amount: { value: '51.79' } },
    }] },
  }],
};

const noStreet = (v: unknown) => {
  const s = JSON.stringify(v);
  expect(s).not.toContain('Evergreen');
  expect(s).not.toContain('Main St');
  expect(s).not.toContain('Apt');
  expect(s).not.toContain('line1');
  expect(s).not.toContain('address_line');
};

describe('cleaning', () => {
  it('keeps an ISO alpha-2 country only', () => {
    expect(cleanCountry(' us ')).toBe('US');
    expect(cleanCountry('USA')).toBeNull();
    expect(cleanCountry('')).toBeNull();
    expect(cleanCountry(840)).toBeNull();
  });
  it('flattens free text and caps it', () => {
    expect(cleanPart('  New\tYork\n ', 80)).toBe('New York');
    expect(cleanPart('   ', 80)).toBeNull();
    expect(cleanPart('x'.repeat(200), 80)).toHaveLength(80);
    expect(cleanPart(null, 80)).toBeNull();
  });
  it('accepts plausible postal codes only', () => {
    expect(cleanPostal(' sw1a  1aa ')).toBe('SW1A 1AA');
    expect(cleanPostal('11211-1234')).toBe('11211-1234');
    expect(cleanPostal('<script>')).toBeNull();
    expect(cleanPostal('1'.repeat(17))).toBeNull();
  });
});

describe('Stripe', () => {
  it('reads the Checkout Session billing address without the street', () => {
    const loc = locationFromStripeSession(SESSION);
    expect(loc).toEqual({ country: 'US', region: 'NY', city: 'Brooklyn', postal_code: '11211', source: 'stripe_billing' });
    noStreet(loc);
    noStreet(locationRpcArgs(SESSION.id, loc!));
    expect(Object.keys(locationRpcArgs(SESSION.id, loc!)).sort())
      .toEqual(['p_city', 'p_country', 'p_postal_code', 'p_region', 'p_session_id', 'p_source']);
  });
  it('has nothing when Checkout collected no country (or no details at all)', () => {
    expect(locationFromStripeSession({ ...SESSION, customer_details: { ...SESSION.customer_details, address: { country: null, postal_code: '11211' } } })).toBeNull();
    expect(locationFromStripeSession({ ...SESSION, customer_details: null })).toBeNull();
    expect(locationFromStripeSession(null)).toBeNull();
  });
  it('a country-and-postal-only session (the auto default) still counts', () => {
    expect(locationFromStripeSession({ customer_details: { address: { country: 'US', postal_code: '10001', city: null, state: null, line1: null } } }))
      .toEqual({ country: 'US', region: null, city: null, postal_code: '10001', source: 'stripe_billing' });
  });
  it('falls back to the charge: billing address first, then the card country', () => {
    const loc = locationFromStripeCharge(CHARGE);
    expect(loc).toEqual({ country: 'CA', region: 'ON', city: 'Toronto', postal_code: 'M5V 2T6', source: 'stripe_card_billing' });
    noStreet(loc);
    const cardOnly = locationFromStripeCharge({ ...CHARGE, billing_details: { address: { city: null, country: null, line1: null } } });
    expect(cardOnly).toEqual({ country: 'GB', region: null, city: null, postal_code: null, source: 'stripe_card_country' });
    expect(locationFromStripeCharge({ id: 'ch_1' })).toBeNull();
  });
});

describe('PayPal', () => {
  it("reads the payer's address on the funding source, never the street", () => {
    const loc = locationFromPayPalOrder(PAYPAL_CAPTURED);
    expect(loc).toEqual({ country: 'US', region: 'CA', city: 'San Jose', postal_code: '95131', source: 'paypal_payer' });
    noStreet(loc);
  });
  it('then payer.address, then the shipping address', () => {
    const { payment_source: _ps, ...noSource } = PAYPAL_CAPTURED;
    expect(locationFromPayPalOrder(noSource)).toEqual({ country: 'US', region: null, city: null, postal_code: null, source: 'paypal_payer' });
    const { payer: _p, ...noPayer } = noSource;
    const ship = locationFromPayPalOrder(noPayer);
    expect(ship).toEqual({ country: 'US', region: 'TX', city: 'Austin', postal_code: '78701', source: 'paypal_shipping' });
    noStreet(ship);
    expect(locationFromPayPalOrder({ id: 'X', payment_source: { venmo: { address: { country_code: 'us', admin_area_2: 'Miami' } } } }))
      .toMatchObject({ country: 'US', city: 'Miami', source: 'paypal_payer' });
    expect(locationFromPayPalOrder({ id: 'X', payment_source: { paypal: {} }, purchase_units: [{}] })).toBeNull();
  });
});

describe('recordBuyerLocation', () => {
  const loc = locationFromStripeSession(SESSION);
  it('calls exos_record_order_location once with the cleaned fields', async () => {
    const rpc = vi.fn(async () => ({ data: 'recorded', error: null }));
    expect(await recordBuyerLocation({ rpc }, 'cs_1', loc, () => undefined)).toBe('recorded');
    expect(rpc).toHaveBeenCalledWith('exos_record_order_location', {
      p_session_id: 'cs_1', p_country: 'US', p_region: 'NY', p_city: 'Brooklyn', p_postal_code: '11211', p_source: 'stripe_billing',
    });
  });
  it("never throws: no location, a DB error, the migration not yet applied", async () => {
    const log = vi.fn();
    expect(await recordBuyerLocation({ rpc: vi.fn() }, 'cs_1', null, log)).toBe('none');
    expect(await recordBuyerLocation({ rpc: async () => ({ data: null, error: { code: 'XX000', message: 'boom' } }) }, 'cs_1', loc, log)).toBe('error');
    expect(log).toHaveBeenCalledTimes(1);
    expect(await recordBuyerLocation({ rpc: async () => ({ data: null, error: { code: 'PGRST202' } }) }, 'cs_1', loc, log)).toBe('error');
    expect(log).toHaveBeenCalledTimes(1); // not applied yet: quiet
    expect(await recordBuyerLocation({ rpc: async () => { throw new Error('network'); } }, 'cs_1', loc, log)).toBe('error');
    expect(await recordBuyerLocation({ rpc: async () => ({ data: 'skipped:free', error: null }) }, 'cs_1', loc, log)).toBe('skipped');
    expect(await recordBuyerLocation({ rpc: async () => ({ data: 'kept', error: null }) }, 'cs_1', loc, log)).toBe('kept');
  });
});

describe('the fee read hands its charge to the location fallback', () => {
  function db(): FeeDb {
    const q = (row: unknown) => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: row, error: null }) }) }) });
    return {
      from: (t: string) => (t === 'exos_order_payments' ? q({ fees_recorded_at: null }) : q({ application_fee_cents: 417 })),
      rpc: async () => ({ data: null, error: null }),
    };
  }
  const stripe: FeeStripe = { paymentIntents: { retrieve: async () => ({ latest_charge: CHARGE as ChargeLike }) } };
  it('calls onCharge with the charge it already fetched (no second Stripe read)', async () => {
    const seen: unknown[] = [];
    const retrieve = vi.spyOn(stripe.paymentIntents, 'retrieve');
    expect(await recordFeeActuals(db(), stripe, 'cs_1', 'pi_1', { onCharge: (c) => { seen.push(locationFromStripeCharge(c)); } })).toBe('recorded');
    expect(retrieve).toHaveBeenCalledTimes(1);
    expect(seen).toEqual([{ country: 'CA', region: 'ON', city: 'Toronto', postal_code: 'M5V 2T6', source: 'stripe_card_billing' }]);
  });
  it('an onCharge failure is logged and the fees still record', async () => {
    const log = vi.fn();
    expect(await recordFeeActuals(db(), stripe, 'cs_1', 'pi_1', { log, onCharge: () => { throw new Error('x'); } })).toBe('recorded');
    expect(log).toHaveBeenCalledTimes(1);
  });
});

describe('PayPal capture records the location', () => {
  const CFG: PayPalConfig = { env: 'sandbox', baseUrl: PAYPAL_HOSTS.sandbox, clientId: 'cid', clientSecret: 'sec', webhookId: 'WH-1' };
  const SID = 'pp_0123456789abcdef0123456789abcdef';
  const fetcher = vi.fn(async (url: string) => {
    if (url.endsWith('/v1/oauth2/token')) return new Response(JSON.stringify({ access_token: 't', expires_in: 3600 }), { status: 200 });
    if (url.endsWith('/capture')) return new Response(JSON.stringify(PAYPAL_CAPTURED), { status: 201 });
    return new Response('{}', { status: 599 });
  });
  function fakeDb(session_status: string) {
    const calls: { fn: string; args: Record<string, unknown> }[] = [];
    const db: Db = {
      rpc: async (fn, args) => {
        calls.push({ fn, args });
        if (fn === 'exos_paypal_capture_gate') return { data: { ok: true, session_id: SID, status: 'pending' }, error: null };
        if (fn === 'exos_paypal_record_capture') return { data: { session_id: SID, session_status, payment_status: 'succeeded' }, error: null };
        if (fn === 'exos_record_order_location') return { data: 'recorded', error: null };
        return { data: null, error: { message: `unexpected ${fn}` } };
      },
      rows: async () => [],
    };
    return { db, calls };
  }
  it('after the capture, with no street', async () => {
    const pp = createPayPalClient(CFG, fetcher as unknown as typeof fetch);
    const { db, calls } = fakeDb('fulfilled');
    expect((await captureOrder(db, pp, '5O190127TN364715T', () => undefined)).http).toBe(200);
    expect(calls.map((c) => c.fn)).toEqual(['exos_paypal_capture_gate', 'exos_paypal_record_capture', 'exos_record_order_location']);
    expect(calls[2].args).toEqual({
      p_session_id: SID, p_country: 'US', p_region: 'CA', p_city: 'San Jose', p_postal_code: '95131', p_source: 'paypal_payer',
    });
    noStreet(calls[2].args);
  });
});
