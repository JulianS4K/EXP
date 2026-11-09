// exos-api: giving and gift card writes (mig 20261102110000, docs/giving.md,
// docs/gift-cards.md, docs/partner-sales.md). Dispatched from index.ts for the
// routes in GIVING_ROUTES; every write runs through a service-role SQL
// function that takes the key's org explicitly.
//
//   POST   /giving-campaigns                   create (a draft until activated)
//   PATCH  /giving-campaigns/:id               update
//   POST   /giving-campaigns/:id/activate      open it
//   POST   /giving-campaigns/:id/complete      close it for good; its monthly
//                                              gifts are cancelled in Stripe
//   DELETE /giving-campaigns/:id               only with no donations (409:
//                                              complete it instead)
//   POST   /giving-campaigns/:id/recurring-donations  a Stripe Checkout link
//                                              for a donor's monthly gift
//   GET    /recurring-donations[/:id], DELETE /recurring-donations/:id (cancel)
//   DELETE /donations/:id                      offline, no payment only (409)
//   POST   /donations/:id/offline-refund       a refund paid outside Stripe
//   POST   /gift-cards/import                  bulk import (Gift Up! and others)
//   GET / POST /events/:id/organizer-reservations/:token/gift-card-redemptions,
//   DELETE …/gift-card-redemptions/:redemption_id
//
// Stripe (monthly gifts) needs STRIPE_SECRET_KEY and EXOS_REDIRECT_ORIGINS;
// without the key those routes answer 503. Nothing else here calls out.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";
import {
  campaignBody, GivingBodyError, importBody, offlineRefundBody, RECURRING_STATUSES, redemptionBody, unwrapBody,
} from "../_shared/api/giving.ts";
import { normalizeGuestEmail } from "../_shared/guest.ts";
import { isAllowedRedirect, parseRedirectOrigins } from "../_shared/redirects.ts";
import { cancelMonthlyDonation, cancelSubscriptions, createMonthlyDonation } from "../_shared/recurringDonation.ts";
import { Answer, CoreError } from "./core.ts";

export const GIVING_ROUTES = new Set([
  "create-giving-campaign", "update-giving-campaign", "activate-giving-campaign", "complete-giving-campaign",
  "delete-giving-campaign", "create-recurring-donation", "list-recurring-donations", "get-recurring-donation",
  "cancel-recurring-donation", "delete-donation", "offline-refund-donation", "import-gift-cards",
  "list-reservation-gift-cards", "create-reservation-gift-card", "delete-reservation-gift-card",
]);

export interface GivingCtx {
  sb: SupabaseClient;
  orgId: string;
  credId: string;
  params: Record<string, string>;
  q: URLSearchParams;
  page: Page;
  body: Record<string, unknown>;
  idempotencyKey: string | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN_RE = /^rsv_[A-Za-z0-9_-]{43}$/;
const REDEMPTION_RE = /^gcr_[0-9a-f]{32,40}$/;
const RECURRING_COLS =
  "id, campaign_id, amount_cents, cover_fees_cents, currency, interval, status, donor_name, donor_email, anonymous, " +
  "source, current_period_end, last_paid_at, failed_payments, cancel_requested_at, cancelled_at, created_at";

/** SQLSTATEs the giving functions raise, as HTTP answers. */
const STATUS: Record<string, number> = {
  "22023": 400, "22P02": 400, "22007": 400, "22008": 400, "22001": 400, "23514": 400, "23502": 400,
  "42501": 403, "P0002": 404, "23505": 409, "23503": 409, "55000": 409, "54000": 429,
};

function stripe(): Stripe | null {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  return key ? new Stripe(key, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" }) : null;
}

async function call(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) {
    const st = STATUS[String(error.code ?? "")];
    if (st) throw new CoreError(st, String(error.message ?? "invalid request").slice(0, 300));
    throw error;
  }
  return data;
}

function uuid(raw: string | undefined, what: string): string {
  if (!raw || !UUID_RE.test(raw)) throw new CoreError(404, `${what} not found`);
  return raw.toLowerCase();
}

/** The organizer reservation :token of event :id in this org (404 otherwise). */
async function reservationToken(c: GivingCtx): Promise<string> {
  const ev = uuid(c.params.id, "event");
  const token = c.params.token;
  if (!token || !TOKEN_RE.test(token)) throw new CoreError(404, "reservation not found");
  const { data, error } = await c.sb.from("exos_partner_reservations").select("id")
    .eq("org_id", c.orgId).eq("event_id", ev).eq("token", token).eq("channel", "organizer").maybeSingle();
  if (error) throw error;
  if (!data) throw new CoreError(404, "reservation not found");
  return token;
}

export async function handleGiving(route: ApiRoute, c: GivingCtx): Promise<unknown> {
  try {
    return await dispatch(route, c);
  } catch (e) {
    if (e instanceof GivingBodyError) throw new CoreError(400, e.message);
    throw e;
  }
}

async function dispatch(route: ApiRoute, c: GivingCtx): Promise<unknown> {
  const { sb, orgId } = c;
  switch (route.id) {
    // -- Campaigns -------------------------------------------------------------
    case "create-giving-campaign": {
      const out = await call(sb, "exos_api_giving_campaign_op", {
        p_org_id: orgId, p_op: "create", p_id: null, p_body: campaignBody(c.body),
      }) as { campaign: unknown };
      return new Answer(201, { data: out.campaign });
    }
    case "update-giving-campaign":
    case "activate-giving-campaign":
    case "delete-giving-campaign": {
      const op = route.id === "update-giving-campaign" ? "update" : route.id === "activate-giving-campaign" ? "activate" : "delete";
      const out = await call(sb, "exos_api_giving_campaign_op", {
        p_org_id: orgId, p_op: op, p_id: uuid(c.params.id, "campaign"), p_body: op === "update" ? campaignBody(c.body) : {},
      }) as { campaign: unknown };
      return { data: out.campaign };
    }
    case "complete-giving-campaign": {
      const out = await call(sb, "exos_api_giving_campaign_op", {
        p_org_id: orgId, p_op: "complete", p_id: uuid(c.params.id, "campaign"), p_body: {},
      }) as { campaign: unknown; cancel_subscriptions: string[] };
      const left = await cancelSubscriptions(stripe(), out.cancel_subscriptions ?? []);
      return { data: out.campaign, monthly_gifts_cancelled: (out.cancel_subscriptions ?? []).length - left.length,
        monthly_gifts_not_cancelled: left.length };
    }

    // -- Monthly gifts -------------------------------------------------------------
    case "create-recurring-donation": {
      const b = unwrapBody(c.body, "recurring_donation");
      const email = normalizeGuestEmail(b.email ?? b.donor_email);
      if (!email) throw new CoreError(400, "email is required (the donor's receipts go there).");
      const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
      if (!isAllowedRedirect(b.success_url, allowed) || !isAllowedRedirect(b.cancel_url, allowed)) {
        throw new CoreError(400, "success_url and cancel_url must be on an allowed origin.");
      }
      const r = await createMonthlyDonation(sb, stripe(), (k) => Deno.env.get(k), {
        campaignId: uuid(c.params.id, "campaign"), amountCents: b.amount_cents, coverFees: b.cover_fees === true || b.cover_fees === "true",
        anonymous: b.anonymous === true || b.anonymous === "true", donorName: typeof b.donor_name === "string" ? b.donor_name : null,
        note: typeof b.note === "string" ? b.note : null, donorEmail: email.toLowerCase(), donorUid: null,
        successUrl: String(b.success_url), cancelUrl: String(b.cancel_url), source: "api", orgId,
      });
      if ("error" in r) throw new CoreError(r.status, r.error);
      return new Answer(201, { data: { recurring_donation_id: r.recurring_id, checkout_url: r.url, session_id: r.session_id,
        amount_cents: r.amount_cents, cover_fees_cents: r.cover_fees_cents, currency: r.currency, interval: "month", status: "pending" } });
    }
    case "list-recurring-donations": {
      let q = sb.from("exos_recurring_donations").select(RECURRING_COLS, { count: "exact" }).eq("org_id", orgId);
      const st = c.q.get("status");
      if (st !== null) {
        if (!(RECURRING_STATUSES as readonly string[]).includes(st)) throw new CoreError(400, "status is invalid.");
        q = q.eq("status", st);
      }
      const camp = c.q.get("campaign_id");
      if (camp !== null) {
        if (!UUID_RE.test(camp)) throw new CoreError(400, "campaign_id must be a UUID.");
        q = q.eq("campaign_id", camp);
      }
      const r = await q.order("created_at", { ascending: false }).order("id").range(c.page.from, c.page.to);
      if (r.error) {
        if (r.error.code === "PGRST103") return pageEnvelope([], c.page, null);
        throw r.error;
      }
      return pageEnvelope(r.data ?? [], c.page, r.count);
    }
    case "get-recurring-donation": {
      const { data, error } = await sb.from("exos_recurring_donations").select(RECURRING_COLS)
        .eq("org_id", orgId).eq("id", uuid(c.params.id, "recurring donation")).maybeSingle();
      if (error) throw error;
      if (!data) throw new CoreError(404, "recurring donation not found");
      return { data };
    }
    case "cancel-recurring-donation": {
      const id = uuid(c.params.id, "recurring donation");
      try {
        return { data: await cancelMonthlyDonation(sb, stripe(), orgId, id, "cancelled through the API") };
      } catch (e) {
        const st = (e as { status?: number }).status;
        if (st) throw new CoreError(st, (e as Error).message);
        const code = String((e as { code?: string }).code ?? "");
        if (STATUS[code]) throw new CoreError(STATUS[code], String((e as Error).message));
        throw e;
      }
    }

    // -- Donations -------------------------------------------------------------------
    case "delete-donation":
      return { data: await call(sb, "exos_api_donation_op", {
        p_org_id: orgId, p_op: "delete", p_id: uuid(c.params.id, "donation"), p_body: {},
      }) };
    case "offline-refund-donation": {
      const out = await call(sb, "exos_api_donation_op", {
        p_org_id: orgId, p_op: "offline_refund", p_id: uuid(c.params.id, "donation"),
        p_body: offlineRefundBody(c.body, c.idempotencyKey),
      }) as { fresh: boolean; donation: unknown };
      return out.fresh ? new Answer(201, { data: out.donation }) : { data: out.donation };
    }

    // -- Gift card import ---------------------------------------------------------
    case "import-gift-cards": {
      const { source, cards } = importBody(c.body);
      const out = await call(sb, "exos_api_gift_card_import", {
        p_org_id: orgId, p_source: source, p_cards: cards, p_key: c.idempotencyKey ? `api:${c.idempotencyKey}` : null,
      }) as Record<string, unknown>;
      return new Answer(out.fresh ? 201 : 200, { data: out });
    }

    // -- Gift cards on organizer reservations ----------------------------------------
    case "list-reservation-gift-cards": {
      const token = await reservationToken(c);
      return { data: await call(sb, "_exos_reservation_gift_cards", { p_org_id: orgId, p_partner_id: null, p_token: token }) };
    }
    case "create-reservation-gift-card": {
      const token = await reservationToken(c);
      const { code, amountCents } = redemptionBody(c.body);
      const out = await call(sb, "_exos_reservation_gift_card_apply", {
        p_org_id: orgId, p_partner_id: null, p_token: token, p_code: code, p_amount_cents: amountCents,
        p_bucket: `api:${c.credId}`, p_key: c.idempotencyKey,
      }) as Record<string, unknown>;
      if (out.error) {
        const msg = String(out.error);
        throw new CoreError(msg.startsWith("too many") ? 429 : 422, msg, { reason: "gift_card" });
      }
      return out.fresh ? new Answer(201, { data: out }) : { data: out };
    }
    case "delete-reservation-gift-card": {
      const token = await reservationToken(c);
      const rid = c.params.rid;
      if (!rid || !REDEMPTION_RE.test(rid)) throw new CoreError(404, "gift card redemption not found");
      return { data: await call(sb, "_exos_reservation_gift_card_remove", {
        p_org_id: orgId, p_partner_id: null, p_token: token, p_redemption_id: rid,
      }) };
    }
  }
  throw new CoreError(404, "not found");
}
