// Promo links (mig 20261016110000): a voucher with a label and a channel,
// shared as a URL that opens the event page with the code applied. The
// voucher's max_uses is the redemption limit; visits are counted per link.

import { supabase } from './supabase';
import { publicUrl } from './utils';

export interface PromoLink {
  voucherId: string;
  code: string;
  label: string;
  channel: string | null;
  clicks: number;
  used: number;
  maxUses: number;
  validUntil: Date | null;
  discountPercent: number | null;
  discountAmount: number | null;
  tierId: string | null;
}

export const CHANNELS = ['instagram', 'tiktok', 'sms', 'email', 'facebook', 'x', 'whatsapp', 'flyer', 'partner'] as const;

/** A code fans can type: letters / digits, 4-24, upper case. */
export function cleanCode(raw: string): string {
  return raw.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 24);
}

export function slugChannel(raw: string): string {
  return raw.toLowerCase().trim().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
}

/** The shareable URL: event page + code + UTM so the sale is attributed. */
export function promoUrl(eventId: string, link: Pick<PromoLink, 'code' | 'channel' | 'label'>, base = publicUrl(`event/${eventId}`)): string {
  const q = new URLSearchParams({ code: link.code });
  q.set('utm_source', link.channel || 'promo');
  q.set('utm_medium', 'promo_link');
  q.set('utm_campaign', slugChannel(link.label) || 'promo');
  return `${base}?${q}`;
}

/** The code from an event-page URL (?code=), if it looks like one. */
export function codeFromSearch(search: string): string | null {
  const c = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search).get('code');
  if (!c) return null;
  const s = c.trim();
  return /^[A-Za-z0-9_-]{3,64}$/.test(s) ? s : null;
}

export function redemptionText(l: Pick<PromoLink, 'used' | 'maxUses'>): string {
  const left = Math.max(0, l.maxUses - l.used);
  return left === 0 ? `All ${l.maxUses} used` : `${l.used} of ${l.maxUses} used · ${left} left`;
}

export function dealText(l: Pick<PromoLink, 'discountPercent' | 'discountAmount'>, currency = 'USD'): string {
  if (l.discountPercent) return `${Number(l.discountPercent)}% off`;
  if (l.discountAmount) {
    try {
      return `${new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(Number(l.discountAmount))} off`;
    } catch {
      return `${l.discountAmount} off`;
    }
  }
  return 'No discount (tracking only)';
}

export function parsePromoLink(r: any): PromoLink {
  return {
    voucherId: String(r.voucher_id),
    code: String(r.code),
    label: String(r.label ?? ''),
    channel: r.channel ?? null,
    clicks: Number(r.clicks) || 0,
    used: Number(r.used) || 0,
    maxUses: Number(r.max_uses) || 0,
    validUntil: r.valid_until ? new Date(r.valid_until) : null,
    discountPercent: r.discount_percent != null ? Number(r.discount_percent) : null,
    discountAmount: r.discount_amount != null ? Number(r.discount_amount) : null,
    tierId: r.tier_id ?? null,
  };
}

export async function listPromoLinks(eventId: string): Promise<PromoLink[]> {
  const { data, error } = await supabase.rpc('exos_promo_links', { p_event_id: eventId });
  if (error) throw error;
  return (Array.isArray(data) ? data : []).map(parsePromoLink);
}

export async function createPromoLink(input: {
  eventId: string; label: string; channel: string; maxUses: number; validHours?: number | null;
  code?: string; discountPercent?: number | null; discountAmount?: number | null; tierId?: string | null;
}): Promise<string> {
  const { data, error } = await supabase.rpc('exos_create_promo_link', {
    p_event_id: input.eventId, p_label: input.label.trim(), p_channel: slugChannel(input.channel) || null,
    p_max_uses: input.maxUses, p_valid_hours: input.validHours ?? null, p_code: input.code ? cleanCode(input.code) : null,
    p_discount_percent: input.discountPercent ?? null, p_discount_amount: input.discountAmount ?? null, p_tier_id: input.tierId ?? null,
  });
  if (error) throw new Error(error.message.replace(/^exos_\w+: /, ''));
  return String(data);
}

/** Count a visit from a promo link (fire and forget; answers nothing). */
export function recordPromoHit(eventId: string, code: string): void {
  void supabase.rpc('exos_promo_link_hit', { p_event_id: eventId, p_code: code }).then(() => {}, () => {});
}
