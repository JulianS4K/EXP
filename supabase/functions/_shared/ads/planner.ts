// "Boost this event": the one campaign planner every ad platform's adapter
// builds its requests from (ads phase, mig 20261121190500). Pure.
//
// From the event (exos_ads_campaign_context) it decides what any platform's
// campaign would say: the name, the copy, the image, the link (with UTM
// tags), the dates, the budget, the geo (geo.ts) and the communities, plus
// warnings for the organizer. Each adapter (metaAds.ts, redditAds.ts) turns
// this into its platform's calls; every campaign is created PAUSED, and every
// call is a dry run behind GatedHttp.
//
// PRICE. What Exos charges an organizer for a boost is a config value,
// EXOS_ADS_BOOST_PRICE_CENTS, that defaults to 0 (free at first). The ad
// budget (paid to the platform from the organizer's own ad account) is the
// organizer's number, also 0 unless given: a $0 budget can't run, so the
// plan says so, and nothing runs anyway until it is switched on and
// unpaused.

import { adGeo, communitiesFor, type AdGeo } from "./geo.ts";

export interface BoostConfig {
  /** What Exos charges for a boost, in cents. Default 0: free at first. */
  priceCents: number;
  /** The ad budget per day, in the event's currency's cents. Default 0. */
  dailyBudgetCents: number;
}

export const BOOST_DEFAULTS: BoostConfig = { priceCents: 0, dailyBudgetCents: 0 };

const cents = (v: unknown, fallback: number): number => {
  const n = typeof v === "string" && v.trim() !== "" ? Number(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) && n >= 0 ? Math.min(Math.round(n), 100_000_000) : fallback;
};

/** The boost config: env EXOS_ADS_BOOST_PRICE_CENTS (default 0) and the organizer's daily budget (default 0). */
export function boostConfig(env: (k: string) => string | undefined | null, req: { daily_budget_cents?: unknown } = {}): BoostConfig {
  return {
    priceCents: cents(env("EXOS_ADS_BOOST_PRICE_CENTS"), BOOST_DEFAULTS.priceCents),
    dailyBudgetCents: cents(req.daily_budget_cents, BOOST_DEFAULTS.dailyBudgetCents),
  };
}

/** The event as exos_ads_campaign_context returns it. */
export interface CampaignEventInput {
  id: string;
  name: string;
  slug?: string | null;
  status?: string | null;
  starts_at?: string | null;
  ends_at?: string | null;
  timezone?: string | null;
  currency?: string | null;
  image_url?: string | null;
  description?: string | null;
  venue_name?: string | null;
  venue_location?: string | null;
  venue_address?: unknown;
  lat?: number | null;
  lng?: number | null;
  min_price_cents?: number | null;
  free?: boolean | null;
  hidden?: boolean | null;
}

export interface CampaignPlan {
  eventId: string;
  name: string;
  headline: string;
  body: string;
  imageUrl: string | null;
  /** The event page; each adapter adds its own utm_source. */
  url: string | null;
  cta: "BUY_TICKETS";
  startTime: string;
  endTime: string | null;
  dailyBudgetCents: number;
  priceCents: number;
  currency: string;
  geo: AdGeo;
  communities: string[];
  /** Shown to the organizer; the plan is still made. */
  warnings: string[];
  /** The campaign can't run at all (a past or cancelled event): adapters plan nothing. */
  blocked: string | null;
}

const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);
const money = (c: number, cur: string) => `${cur === "USD" ? "$" : ""}${(c / 100).toFixed(2)}${cur === "USD" ? "" : ` ${cur}`}`;

function when(iso: string | null | undefined, tz: string | null | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  try {
    return d.toLocaleString("en-US", { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: tz || "America/New_York" });
  } catch {
    return d.toISOString().slice(0, 16).replace("T", " ");
  }
}

/** The event page with the boost's UTM tags (utm_source is the platform's). */
export function boostUrl(appBase: string, ev: Pick<CampaignEventInput, "id" | "slug">, source: string): string | null {
  const base = (appBase || "").replace(/\/+$/, "");
  if (!/^https:\/\//.test(base) || !ev.id) return null;
  const path = ev.slug ? `/e/${encodeURIComponent(ev.slug)}` : `/event/${encodeURIComponent(ev.id)}`;
  const q = new URLSearchParams({ utm_source: source, utm_medium: "paid", utm_campaign: `exos_boost_${ev.id.slice(0, 8)}` });
  return `${base}${path}?${q.toString()}`;
}

export function planCampaign(ev: CampaignEventInput, cfg: BoostConfig, opts: { appBase: string; now?: Date }): CampaignPlan {
  const now = opts.now ?? new Date();
  const warnings: string[] = [];
  let blocked: string | null = null;
  const currency = (ev.currency || "USD").toUpperCase();
  const starts = ev.starts_at ? Date.parse(ev.starts_at) : NaN;
  if (ev.status === "cancelled") blocked = "The event is cancelled.";
  else if (Number.isFinite(starts) && starts <= now.getTime()) blocked = "The event has already started.";
  if (ev.status && ev.status !== "published" && !blocked) warnings.push("The event isn't published yet: the ads would point at a page buyers can't open.");
  if (ev.hidden) warnings.push("Every ticket type is hidden: buyers from the ads would find nothing to buy.");
  if (!ev.image_url) warnings.push("The event has no image: add one, the ads use it.");
  if (cfg.dailyBudgetCents <= 0) warnings.push("The daily budget is $0: set one before switching the campaign on (it is created paused either way).");
  const geo = adGeo(ev);
  if (geo.kind === "none") warnings.push(geo.reason);
  const url = boostUrl(opts.appBase, ev, "exos");
  if (!url) warnings.push("The app address (EXOS_APP_BASE_URL) isn't set: the ads have no link yet.");

  const date = when(ev.starts_at, ev.timezone);
  const price = ev.free ? "Free" : typeof ev.min_price_cents === "number" && ev.min_price_cents > 0 ? `Tickets from ${money(ev.min_price_cents, currency)}` : null;
  const venue = ev.venue_name ? ` at ${ev.venue_name}` : "";
  const body = clip([date ? `${date}${venue}.` : venue ? `${venue.trim()}.` : "", price ? `${price}.` : "", "Get tickets on Exos."]
    .filter(Boolean).join(" "), 300);
  const city = geo.kind === "none" ? null : geo.city;

  return {
    eventId: ev.id,
    name: clip(`Exos boost: ${ev.name}`, 100),
    headline: clip(ev.name, 90),
    body,
    imageUrl: ev.image_url || null,
    url,
    cta: "BUY_TICKETS",
    startTime: now.toISOString(),
    endTime: Number.isFinite(starts) ? new Date(starts).toISOString() : null,
    dailyBudgetCents: cfg.dailyBudgetCents,
    priceCents: cfg.priceCents,
    currency,
    geo,
    communities: communitiesFor(city),
    warnings,
    blocked,
  };
}
