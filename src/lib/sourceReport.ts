// Sales by source, for the event report's Marketing tab (SourcesPanel).
//
// One row per paid checkout (exos_checkout_sessions, statuses fulfilled /
// partially_refunded / refunded), grouped by where the buyer came from:
//   * utm_source / utm_medium / utm_campaign from `attribution` (mig
//     20260924223000), lower-cased so "Instagram" and "instagram" merge;
//   * the promoter code (promoter_id, else attribution.promoter);
//   * the ad platform, inferred from the click id on the landing URL (`ad_ids`,
//     mig 20260929131000; fbclid also lives in attribution). A click id means
//     the buyer clicked through from that platform. It doesn't prove the click
//     was a paid ad (Meta adds fbclid to organic links too).
//   * the AI assistant the buyer came from: `attribution.ai_ref` (the referrer
//     on landing, lib/attribution.ts) or a utm_source an assistant puts on its
//     links (chatgpt.com, perplexity…) or our MCP links (ai_assistant);
// A checkout with none of these is "Direct / unknown".
//
// Pure: no I/O. The read is in components/SourcesPanel.tsx. Gross is what
// the buyer was charged (amount_cents, before refunds); refunded orders are
// counted beside it.

import type { CsvCell } from './csv';
import { aiFromUtmSource, sanitizeAiAssistant, type AiAssistant } from '../../supabase/functions/_shared/aiSources.ts';

export interface SourceSessionRow {
  session_id: string;
  status: string;
  quantity: number | null;
  amount_cents: number | null;
  currency: string | null;
  promoter_id?: string | null;
  attribution?: Record<string, unknown> | null;
  ad_ids?: Record<string, unknown> | null;
}

export type AdPlatform = 'Google' | 'Meta' | 'TikTok' | 'Reddit' | 'Snap' | 'X' | 'Microsoft';

/** Click id key → platform, in the order a tie is broken (a session rarely has two). */
export const CLICK_ID_PLATFORM: readonly (readonly [string, AdPlatform])[] = [
  ['gclid', 'Google'],
  ['gbraid', 'Google'],
  ['wbraid', 'Google'],
  ['fbclid', 'Meta'],
  ['fbc', 'Meta'],
  ['ttclid', 'TikTok'],
  ['rdt_cid', 'Reddit'],
  ['ScCid', 'Snap'],
  ['twclid', 'X'],
  ['msclkid', 'Microsoft'],
];

export const DIRECT_LABEL = 'Direct / unknown';

const COUNTED = new Set(['fulfilled', 'partially_refunded', 'refunded']);

const str = (v: unknown): string | undefined => {
  if (typeof v !== 'string') return undefined;
  const t = v.trim();
  return t ? t : undefined;
};

/** The ad platform a checkout's click ids point to, or null. */
export function adPlatformOf(adIds: Record<string, unknown> | null | undefined, attribution?: Record<string, unknown> | null): AdPlatform | null {
  for (const [key, platform] of CLICK_ID_PLATFORM) {
    if (str(adIds?.[key])) return platform;
  }
  if (str(attribution?.fbclid)) return 'Meta';
  return null;
}

export interface SourceKey {
  source: string | null;
  medium: string | null;
  campaign: string | null;
  promoter: string | null;
  platform: AdPlatform | null;
  assistant: AiAssistant | null;
}

/** The AI assistant a checkout came from, or null. */
export function aiAssistantOf(attribution: Record<string, unknown> | null | undefined): AiAssistant | null {
  return sanitizeAiAssistant(attribution?.ai_ref) ?? aiFromUtmSource(attribution?.utm_source) ?? null;
}

/** Where one checkout came from. */
export function sourceKeyOf(r: SourceSessionRow): SourceKey {
  const a = r.attribution ?? null;
  const lower = (v: unknown) => str(v)?.toLowerCase() ?? null;
  return {
    source: lower(a?.utm_source),
    medium: lower(a?.utm_medium),
    campaign: lower(a?.utm_campaign),
    promoter: str(r.promoter_id) ?? str(a?.promoter) ?? null,
    platform: adPlatformOf(r.ad_ids, a),
    assistant: aiAssistantOf(a),
  };
}

export function isDirect(k: SourceKey): boolean {
  return !k.source && !k.medium && !k.campaign && !k.promoter && !k.platform && !k.assistant;
}

export type SourceDimension = 'all' | 'source' | 'campaign' | 'promoter' | 'platform' | 'assistant';

export interface SourceRow extends SourceKey {
  /** Display label for the row's group. */
  label: string;
  /** The group with nothing for this breakdown ("Direct / unknown" for 'all'). */
  direct: boolean;
  orders: number;
  tickets: number;
  grossCents: number;
  refundedOrders: number;
}

export interface SourceSummary {
  rows: SourceRow[];
  orders: number;
  tickets: number;
  grossCents: number;
  /** Orders with any source (not direct). */
  attributedOrders: number;
  currency: string;
  mixedCurrencies: boolean;
}

const NONE: SourceKey = { source: null, medium: null, campaign: null, promoter: null, platform: null, assistant: null };

/** Project a key onto the chosen dimension (the other parts become null). */
function project(k: SourceKey, dim: SourceDimension): SourceKey {
  switch (dim) {
    case 'all': return k;
    case 'source': return { ...NONE, source: k.source, medium: k.medium };
    case 'campaign': return { ...NONE, campaign: k.campaign };
    case 'promoter': return { ...NONE, promoter: k.promoter };
    case 'platform': return { ...NONE, platform: k.platform };
    case 'assistant': return { ...NONE, assistant: k.assistant };
  }
}

/** The empty group's label per breakdown ("Direct / unknown" when every part is empty). */
export const EMPTY_LABEL: Record<SourceDimension, string> = {
  all: DIRECT_LABEL,
  source: 'No UTM source',
  campaign: 'No campaign',
  promoter: 'No promoter',
  platform: 'No ad click id',
  assistant: 'Not from an AI assistant',
};

function labelOf(k: SourceKey, dim: SourceDimension): string {
  if (isDirect(k)) return EMPTY_LABEL[dim];
  const parts: string[] = [];
  if (k.source || k.medium) parts.push(`${k.source ?? '(none)'} / ${k.medium ?? '(none)'}`);
  if (k.campaign) parts.push(k.campaign);
  if (k.promoter) parts.push(`promoter ${k.promoter}`);
  if (k.platform) parts.push(k.platform);
  if (k.assistant) parts.push(`via ${k.assistant}`);
  return parts.join(' · ');
}

/**
 * Group counted checkouts by source. `dim` picks the breakdown: every part
 * together ('all'), or one of source+medium, campaign, promoter, platform.
 * Rows sort by gross, then orders; "Direct / unknown" always goes last.
 */
export function summarizeSources(sessions: SourceSessionRow[], dim: SourceDimension = 'all', fallbackCurrency = 'USD'): SourceSummary {
  const groups = new Map<string, SourceRow>();
  const currencies = new Set<string>();
  let orders = 0;
  let tickets = 0;
  let grossCents = 0;
  let attributedOrders = 0;
  for (const s of sessions) {
    if (!COUNTED.has(s.status)) continue;
    const full = sourceKeyOf(s);
    const k = project(full, dim);
    const id = JSON.stringify([k.source, k.medium, k.campaign, k.promoter, k.platform, k.assistant]);
    let row = groups.get(id);
    if (!row) {
      row = { ...k, label: labelOf(k, dim), direct: isDirect(k), orders: 0, tickets: 0, grossCents: 0, refundedOrders: 0 };
      groups.set(id, row);
    }
    const qty = typeof s.quantity === 'number' && s.quantity > 0 ? s.quantity : 0;
    const cents = typeof s.amount_cents === 'number' && Number.isFinite(s.amount_cents) ? Math.round(s.amount_cents) : 0;
    row.orders += 1;
    row.tickets += qty;
    row.grossCents += cents;
    if (s.status === 'refunded') row.refundedOrders += 1;
    orders += 1;
    tickets += qty;
    grossCents += cents;
    if (!isDirect(full)) attributedOrders += 1;
    if (s.currency) currencies.add(s.currency.toUpperCase());
  }
  const rows = [...groups.values()].sort((a, b) =>
    Number(a.direct) - Number(b.direct) || b.grossCents - a.grossCents || b.orders - a.orders || a.label.localeCompare(b.label));
  return {
    rows,
    orders,
    tickets,
    grossCents,
    attributedOrders,
    currency: currencies.size === 1 ? [...currencies][0] : fallbackCurrency.toUpperCase(),
    mixedCurrencies: currencies.size > 1,
  };
}

export const SOURCES_CSV_HEADER = [
  'utm_source', 'utm_medium', 'utm_campaign', 'promoter', 'ad_platform', 'ai_assistant', 'orders', 'tickets', 'gross',
  'refunded_orders', 'currency',
];

/** CSV rows for a summary (gross in major units; the empty group's label goes in utm_source). */
export function sourcesCsvRows(s: SourceSummary): CsvCell[][] {
  return s.rows.map((r) => [
    r.direct ? r.label : r.source ?? '',
    r.medium ?? '',
    r.campaign ?? '',
    r.promoter ?? '',
    r.platform ?? '',
    r.assistant ?? '',
    r.orders,
    r.tickets,
    (r.grossCents / 100).toFixed(2),
    r.refundedOrders,
    s.currency,
  ]);
}
