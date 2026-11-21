// The ads phase in the app (mig 20261121190500; docs/marketing-conversions.md
// "Ads"): "Boost this event" and "Sync an audience" ask exos-ads for a plan.
// Everything is a DRY RUN: exos-ads sends nothing to an ad platform, records
// what it would send in "What we'd send" (Org settings) and returns it here.
// Owner / manager (exos-ads checks the role first).
//
// Pure helpers first (vitest), then the calls.

import { supabase } from './supabase';

export type CampaignChannel = 'meta_ads' | 'reddit_ads';
export type AudienceChannel = 'meta_ads' | 'reddit_ads' | 'google_customer_match';

export const CAMPAIGN_CHANNELS: ReadonlyArray<{ id: CampaignChannel; label: string }> = [
  { id: 'meta_ads', label: 'Meta (Facebook and Instagram)' },
  { id: 'reddit_ads', label: 'Reddit' },
];
export const AUDIENCE_CHANNELS: ReadonlyArray<{ id: AudienceChannel; label: string }> = [
  { id: 'meta_ads', label: 'Meta Custom Audience' },
  { id: 'google_customer_match', label: 'Google Customer Match' },
  { id: 'reddit_ads', label: 'Reddit customer list' },
];
export const adsChannelLabel = (id: string): string =>
  ({ meta_ads: 'Meta', reddit_ads: 'Reddit', google_customer_match: 'Google', x_ads: 'X' } as Record<string, string>)[id] ?? id;

export interface AdsStepView {
  op: string;
  method: string;
  path: string;
  live: boolean;
  body: unknown;
  error?: string;
  warnings?: string[];
}

export interface AdsResult {
  channel: string;
  connected: boolean;
  planned: boolean;
  steps: Array<{ op: string; method: string; path: string; planned: boolean; ok: boolean; error?: string }>;
  ids: Record<string, string>;
  warnings: string[];
  deferred?: number;
  stopped?: string;
}

export interface BoostPlan {
  name: string;
  headline: string;
  body: string;
  imageUrl: string | null;
  url: string | null;
  cta: string;
  startTime: string;
  endTime: string | null;
  dailyBudgetCents: number;
  priceCents: number;
  currency: string;
  geo: { kind: 'radius'; miles: number; zips: string[]; boroughs: string[] } | { kind: 'zips'; zips: string[]; boroughs: string[] } | { kind: 'none'; reason: string };
  communities: string[];
  warnings: string[];
  blocked: string | null;
}

export interface BoostPlanResponse {
  dry_run: true;
  connected: Record<string, boolean>;
  plan: BoostPlan;
  channels: Array<{ channel: CampaignChannel; result: AdsResult; steps: AdsStepView[] }>;
}

export interface AudiencePlanResponse {
  dry_run: true;
  connected: Record<string, boolean>;
  channel: AudienceChannel;
  audience: { rows: number; noConsent: number; noIdentifier: number; duplicates: number; members: number; withEmail: number; withPhone: number };
  result: AdsResult;
  steps: AdsStepView[];
}

export function money(cents: number, currency = 'USD'): string {
  try {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(cents / 100);
  } catch {
    return `${(cents / 100).toFixed(2)} ${currency}`;
  }
}

/** Dollars typed by the organizer -> cents (0 for anything that isn't a non-negative amount). */
export function budgetCents(input: string): number {
  const n = Number(String(input).replace(/[$,\s]/g, ''));
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) : 0;
}

/** One line on where the ads would show. */
export function geoLine(geo: BoostPlan['geo']): string {
  if (geo.kind === 'none') return geo.reason;
  const where = geo.boroughs.length ? geo.boroughs.join(', ') : `${geo.zips.length} ZIP codes`;
  return geo.kind === 'radius'
    ? `Within ${geo.miles} miles of the venue (Meta); ${where} by ZIP code (Reddit, which has no radius).`
    : `${where}, by ZIP code (${geo.zips.length} ZIPs).`;
}

/** Every step paused that a platform would create, for the summary line. */
export function pausedSummary(r: AdsResult): string {
  const made = r.steps.filter((s) => s.ok).length;
  const of = r.steps.length;
  const stop = r.stopped ? ` Stopped: ${r.stopped}` : '';
  return `${made} of ${of} step${of === 1 ? '' : 's'} planned; created paused, nothing sent.${stop}`;
}

// ---- calls -----------------------------------------------------------------

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

function adsBase(): string {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  return url ? `${url}/functions/v1/exos-ads` : '';
}

async function post<T>(route: string, body: Record<string, unknown>): Promise<T> {
  const base = adsBase();
  if (!base) throw new Error('Ads planning isn\'t configured here.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  const res = await fetch(`${base}/${route}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${jwt}`, ...(anon ? { apikey: anon } : {}) },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => null);
  if (!res.ok) throw new Error(typeof out?.error === 'string' ? out.error : `Planning failed (${res.status}).`);
  return out as T;
}

export function planBoost(orgId: string, eventId: string, channels: CampaignChannel[], dailyBudget: number): Promise<BoostPlanResponse> {
  return post('plan-campaign', { org: orgId, event: eventId, channels, daily_budget_cents: dailyBudget });
}

export function planAudience(orgId: string, channel: AudienceChannel, eventId?: string | null): Promise<AudiencePlanResponse> {
  return post('plan-audience', { org: orgId, channel, ...(eventId ? { event: eventId } : {}) });
}
