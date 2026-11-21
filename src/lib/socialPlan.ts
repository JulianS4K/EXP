// "Post / list this event" in the app (mig 20261121203000; docs/social.md
// "Posting and listing APIs"): each platform's status from
// exos_social_post_context, and the plan from exos-social. Everything is a
// DRY RUN: exos-social sends nothing to any platform, records what it would
// send in "What we'd send" (Org settings) and returns it here. Owner /
// manager (both check the role first).
//
// Pure helpers first (vitest), then the calls.

import { supabase } from './supabase';
import { PLATFORM_LABEL, SOCIAL_PLATFORMS, type PlatformPost, type SocialPlatform } from '../../supabase/functions/_shared/social/postKit.ts';
import { familyOf, VENDOR_APPS } from '../../supabase/functions/_shared/social/apps.ts';

export { PLATFORM_LABEL, SOCIAL_PLATFORMS };
export type { PlatformPost, SocialPlatform };

/** The store provider each platform's credential lives under. */
export const PLATFORM_PROVIDER: Record<SocialPlatform, string> = {
  instagram: 'ig_publish',
  tiktok: 'tiktok_publish',
  meetup: 'meetup',
  linkedin: 'linkedin',
  google_business: 'google_business',
};

/** What the platform does with the event, in a few words. */
export const PLATFORM_ACTION: Record<SocialPlatform, string> = {
  instagram: 'Post to your Instagram professional account',
  tiktok: 'Photo post on your TikTok (Direct Post)',
  meetup: 'List it in your Meetup Pro group (draft, then published)',
  linkedin: 'An event on your LinkedIn organization page',
  google_business: 'An event post on your venue\'s Google Business Profile',
};

export interface SocialContext {
  org: { id: string; name: string; venue_org: boolean };
  event: Record<string, unknown> & { id: string; name: string };
  connected: Record<string, boolean>;
  facts: {
    meetup_plan: string | null;
    meetup_pro_network: boolean;
    linkedin_org_page: boolean;
    gbp_verified_days: number | null;
    gbp_own_connection: boolean;
  };
}

export interface SocialStepView { op: string; method: string; path: string; live: boolean; body: unknown; error?: string; warnings?: string[] }

export interface SocialPlatformPlan {
  platform: SocialPlatform;
  label: string;
  status: { connected: boolean; provider: string; dryRun: boolean; app: string | null; connect: 'built' | 'stub'; via?: string };
  post: PlatformPost;
  result: {
    channel: string; connected: boolean; planned: boolean; ids: Record<string, string>; warnings: string[]; stopped?: string;
    steps: Array<{ op: string; method: string; path: string; planned: boolean; ok: boolean; error?: string }>;
  };
  steps: SocialStepView[];
}

export interface SocialPlanResponse {
  dry_run: true;
  connected: Record<string, boolean>;
  platforms: SocialPlatformPlan[];
}

export type StatusWord = 'connected' | 'not_connected';
export const STATUS_TEXT: Record<StatusWord, string> = { connected: 'Connected', not_connected: 'Not connected' };

/** A platform's status line before (or without) a plan: connected or not, and always a dry run. */
export function platformStatus(ctx: SocialContext | null, p: SocialPlatform): { word: StatusWord; notes: string[] } {
  const connected = ctx?.connected?.[PLATFORM_PROVIDER[p]] === true;
  const notes: string[] = [];
  const f = ctx?.facts;
  if (p === 'tiktok') notes.push('Posts would be private (only you) until TikTok audits the Exos app.');
  if (p === 'meetup' && f) {
    if (!f.meetup_pro_network) notes.push('Meetup\'s API needs a group on a Meetup Pro network.');
    if (!f.meetup_plan || f.meetup_plan === 'starter') notes.push('Starter plan (or unknown): 10 attendees per event.');
  }
  if (p === 'linkedin' && f && !f.linkedin_org_page) notes.push('Needs a LinkedIn organization page (not a personal profile).');
  if (p === 'google_business' && ctx) {
    if (!ctx.org.venue_org) notes.push('For organizations that run their own venue.');
    if (f && (f.gbp_verified_days === null || f.gbp_verified_days < 60)) notes.push('Needs a Business Profile verified 60+ days ago.');
    if (connected && f && !f.gbp_own_connection) notes.push('Uses your Google connection (it must also allow Business Profile).');
  }
  return { word: connected ? 'connected' : 'not_connected', notes };
}

/** The vendor app a platform connects through, and whether its connect flow exists yet. */
export function connectInfo(p: SocialPlatform): { app: string; built: boolean } {
  const fam = familyOf(PLATFORM_PROVIDER[p]);
  const a = fam ? VENDOR_APPS[fam] : null;
  return { app: a?.label ?? p, built: a?.connect === 'built' };
}

/** One line per platform plan. */
export function planSummary(p: SocialPlatformPlan): string {
  const n = p.steps.length;
  const stop = p.result.stopped ? ` Stopped: ${p.result.stopped}` : '';
  return `${n} request${n === 1 ? '' : 's'} planned; nothing sent.${stop}`;
}

// ---- calls -----------------------------------------------------------------

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

export async function loadSocialContext(orgId: string, eventId: string): Promise<SocialContext> {
  const { data, error } = await supabase.rpc('exos_social_post_context', { p_org_id: orgId, p_event_id: eventId });
  if (error) throw new Error(error.message?.replace(/^exos_\w+: /, '') || 'Could not load the platforms.');
  return data as SocialContext;
}

export async function planSocialPosts(orgId: string, eventId: string, platforms: SocialPlatform[]): Promise<SocialPlanResponse> {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  if (!url) throw new Error('Post planning isn\'t configured here.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  const res = await fetch(`${url}/functions/v1/exos-social/plan`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${jwt}`, ...(anon ? { apikey: anon } : {}) },
    body: JSON.stringify({ org: orgId, event: eventId, platforms }),
  });
  const out = await res.json().catch(() => null);
  if (!res.ok) throw new Error(typeof out?.error === 'string' ? out.error : `Planning failed (${res.status}).`);
  return out as SocialPlanResponse;
}
