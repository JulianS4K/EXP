// Selling on the organizer's OWN marketplace seller accounts (mig
// 20261121214500; docs/marketplace/README.md "Your own marketplace
// accounts"). The allocation is a % of each ticket type's capacity per
// marketplace (floor, at least 1 above 0, never below what that marketplace
// sold); its tickets are static codes and pay no Exos fee. A DRY RUN: Exos
// sends nothing to the marketplaces yet; "Preview" shows what it would send.

import { supabase } from './supabase';

export const BYO_CHANNELS = ['stubhub', 'seatgeek', 'vivid', 'evo'] as const;
export type ByoChannel = typeof BYO_CHANNELS[number];

export const BYO_LABEL: Record<ByoChannel, string> = {
  stubhub: 'StubHub', seatgeek: 'SeatGeek', vivid: 'Vivid Seats', evo: 'Ticket Evolution',
};

export interface ByoTier {
  tier_id: string;
  name: string;
  capacity: number | null;
  price: number | null;
  allocated: number;
  held: number;
  sold: number;
  min_pct: number;
  status: string | null;
  account: string | null;
  skip: string | null;
  listed: boolean;
}

export interface ByoViewChannel {
  channel: ByoChannel;
  provider: string;
  own: boolean;
  pct: number;
  min_pct: number;
  connected: boolean;
  network_ticked: boolean;
  tiers: ByoTier[];
}

export interface ByoView {
  event: { id: string; org_id: string; name: string; status: string; free_tier: boolean };
  dry_run: boolean;
  channels: ByoViewChannel[];
}

export interface ByoStep { op: string; method: string; path: string; live: boolean; body: unknown; error?: string; warnings?: string[] }
export interface ByoChannelPlan {
  channel: ByoChannel;
  label: string;
  pct: number;
  connected: boolean;
  dryRun: boolean;
  result: { warnings: string[]; stopped?: string };
  steps: ByoStep[];
}

/** The seats a % gives a ticket type: floor(capacity x % / 100), at least 1 above 0 (the server's rule). */
export function seatsFor(capacity: number | null, pct: number): number {
  if (!capacity || capacity <= 0 || !(pct > 0)) return 0;
  return Math.max(Math.floor((capacity * pct) / 100), 1);
}

/** The smallest % that keeps what this marketplace already sold (ceil to the hundredth). */
export function minPctFor(capacity: number | null, sold: number): number {
  if (!capacity || capacity <= 0 || sold <= 0) return 0;
  return Math.ceil((sold * 10000) / capacity) / 100;
}

/** Why a % can't be saved, or null. */
export function pctProblem(ch: Pick<ByoViewChannel, 'min_pct' | 'network_ticked'>, pct: number, label: string): string | null {
  if (!Number.isFinite(pct) || pct < 0 || pct > 100) return 'Enter a share from 0 to 100%.';
  if (pct < ch.min_pct) return `${label} already sold ${ch.min_pct}% of a ticket type: the share can't go lower.`;
  if (pct > 0 && ch.network_ticked) return `${label} is ticked under Distribution (the Exos network sells it there): untick it first.`;
  return null;
}

// ---- calls -----------------------------------------------------------------

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};
const clean = (m: string | undefined, fallback: string) => m?.replace(/^exos_\w+: /, '') || fallback;

export async function loadByoView(eventId: string): Promise<ByoView> {
  const { data, error } = await supabase.rpc('exos_byo_allocations_view', { p_event_id: eventId });
  if (error) throw new Error(clean(error.message, 'Could not load your marketplace accounts.'));
  return data as ByoView;
}

export async function setByoAllocation(eventId: string, channel: ByoChannel, pct: number): Promise<unknown> {
  const { data, error } = await supabase.rpc('exos_byo_set_allocation', { p_event_id: eventId, p_channel: channel, p_pct: pct });
  if (error) throw new Error(clean(error.message, 'Could not save the share.'));
  return data;
}

export async function previewByo(orgId: string, eventId: string): Promise<{ dry_run: boolean; channels: ByoChannelPlan[] }> {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  if (!url) throw new Error('The preview isn\'t configured here.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  const res = await fetch(`${url}/functions/v1/exos-byo/plan`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${jwt}`, ...(anon ? { apikey: anon } : {}) },
    body: JSON.stringify({ org: orgId, event: eventId }),
  });
  const out = await res.json().catch(() => null);
  if (!res.ok) throw new Error(typeof out?.error === 'string' ? out.error : `Preview failed (${res.status}).`);
  return out as { dry_run: boolean; channels: ByoChannelPlan[] };
}
