// Group pay (mig 20261110110000): close friends' open Stripe Checkout pages
// whose seat is gone. exos_group_pages_to_expire lists the pending group
// orders that exos_fulfill_checkout would refuse (the group's deadline
// passed, the host ended the group or covered the seat, the friend started
// over on another page); exos-reconcile-checkouts calls expireGroupPages on
// every run (the existing 15-minute cron).
//
// The only Stripe write is POST /v1/checkout/sessions/:id/expire, on the
// platform's own account (Exos creates every Checkout Session there). A page
// Stripe already completed can't be expired: it is left alone, its webhook
// fulfils, fulfilment refuses the seat and the existing auto-refund pays it
// back (the backstop). Pure apart from the two injected clients, so the Deno
// test runs it against mocks.

/** The part of the Stripe SDK this uses (stripe.checkout.sessions). */
export interface PageStripe {
  checkout: {
    sessions: {
      expire(id: string): Promise<{ id: string; status?: string | null }>;
      retrieve(id: string): Promise<{ id: string; status?: string | null; payment_status?: string | null }>;
    };
  };
}

/** The database side: the due list and the row update. */
export interface PageDb {
  due(limit: number): Promise<{ session_id: string; why: string }[]>;
  /** Mark a pending order expired; false when it isn't pending any more. */
  markExpired(sessionId: string, why: string): Promise<boolean>;
}

export interface PageRun {
  due: number;
  expired: number;
  already_closed: number;
  paid: number;
  errors: number;
}

export const GROUP_PAGE_BATCH = 50;

/** The failure reason recorded on an order whose page Exos closed. */
export function groupPageReason(why: string): string {
  const w = /^[a-z_]{1,20}$/.test(why) ? why : "seat_gone";
  return `group seat no longer held (${w}): checkout page closed`;
}

/** Expire each due page at Stripe, then mark the order expired. Never throws. */
export async function expireGroupPages(
  stripe: PageStripe,
  db: PageDb,
  opts: { limit?: number; log?: (msg: string, err?: unknown) => void } = {},
): Promise<PageRun> {
  const log = opts.log ?? (() => undefined);
  const out: PageRun = { due: 0, expired: 0, already_closed: 0, paid: 0, errors: 0 };
  let rows: { session_id: string; why: string }[] = [];
  try {
    rows = await db.due(opts.limit ?? GROUP_PAGE_BATCH);
  } catch (e) {
    log("group pages: due list failed", e);
    out.errors++;
    return out;
  }
  for (const r of rows) {
    // Stripe Checkout Sessions only (PayPal orders have their own capture gate).
    if (!/^cs_[A-Za-z0-9_]{1,250}$/.test(r.session_id)) continue;
    out.due++;
    let closed = false;
    try {
      const cs = await stripe.checkout.sessions.expire(r.session_id);
      closed = cs.status === "expired";
      if (closed) out.expired++;
    } catch (e) {
      // Not expirable: already expired (count it closed), or complete (paid
      // just before: the webhook and the auto-refund handle it).
      try {
        const cs = await stripe.checkout.sessions.retrieve(r.session_id);
        if (cs.status === "expired") {
          closed = true;
          out.already_closed++;
        } else if (cs.status === "complete") {
          out.paid++;
        } else {
          log(`group pages: expire failed for ${r.session_id}`, e);
          out.errors++;
        }
      } catch (e2) {
        log(`group pages: expire and retrieve failed for ${r.session_id}`, e2);
        out.errors++;
      }
    }
    if (!closed) continue;
    try {
      await db.markExpired(r.session_id, r.why);
    } catch (e) {
      // Stripe closed the page; the 15-minute pending sweep marks the row
      // expired from Stripe's answer next time.
      log(`group pages: mark failed for ${r.session_id}`, e);
      out.errors++;
    }
  }
  return out;
}
