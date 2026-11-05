// Partner and organizer reservations on price steps (mig 20261107120000):
// the SQL refuses a line over its step's remainder with XP410 and a DETAIL;
// exos-api answers 409 price_step_remaining, as exos-checkout does.
import { describe, expect, it } from 'vitest';
import { priceStepBody, rpcAnswer, RPC_STATUS } from '../../supabase/functions/_shared/api/request.ts';

const T = '8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f';

describe('a reservation over its price step', () => {
  it('answers 409 price_step_remaining with what is left at this price', () => {
    const a = rpcAnswer({
      code: 'XP410',
      message: 'price_step_remaining: only 2 of GA left at this price; reserve those, then the rest at the next price',
      details: JSON.stringify({ remaining: 2, price_cents: 2000, tier_id: T }),
    });
    expect(RPC_STATUS.XP410).toBe(409);
    expect(a?.status).toBe(409);
    expect(a?.body).toMatchObject({ reason: 'price_step_remaining', remaining: 2, price_cents: 2000, ticket_type_id: T });
    expect(String(a?.body.error)).toMatch(/^price_step_remaining: only 2 of GA/);
  });
  it('keeps the reason with nulls when the detail is not ours', () => {
    expect(priceStepBody({ details: 'garbage' })).toEqual({
      reason: 'price_step_remaining', remaining: null, price_cents: null, ticket_type_id: null,
    });
    expect(priceStepBody({ details: JSON.stringify({ remaining: -1, price_cents: 1.5, tier_id: 7 }) })).toEqual({
      reason: 'price_step_remaining', remaining: null, price_cents: null, ticket_type_id: null,
    });
    expect(priceStepBody(null).reason).toBe('price_step_remaining');
  });
  it('leaves the other partner answers alone', () => {
    expect(rpcAnswer({ code: 'EXSLD', message: 'sold out: GA has 1 left' })?.body).toEqual({
      error: 'sold out: GA has 1 left', reason: 'sold_out',
    });
    expect(rpcAnswer({ code: 'XP409', message: 'price_changed' })).toBeNull();
  });
});
