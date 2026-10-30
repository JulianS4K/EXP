// Last call (mig 20261029100000): once an event's remaining tickets are at or
// below its threshold (default 10), only its primary checkout sells. The
// server decides (exos_event_last_call); this reads it and words it.

import { supabase } from '../supabase';
import { isMissingRpc } from '../door/net';

export type SalePlatform = 'exos' | 'eventbrite' | 'luma';

export const PLATFORM_LABEL: Record<SalePlatform, string> = { exos: 'Exos', eventbrite: 'Eventbrite', luma: 'Luma' };

/** The platform default when no event or org threshold is set. */
export const LAST_CALL_DEFAULT = 10;

const platform = (v: unknown): SalePlatform => (v === 'eventbrite' || v === 'luma' ? v : 'exos');
const intOrNull = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? Math.trunc(v) : null);

/** The rule, as the server applies it: a threshold of 0 is off; no limit is never last call. */
export function isLastCall(remaining: number | null, threshold: number): boolean {
  return remaining !== null && threshold > 0 && remaining <= threshold;
}

/** A threshold typed into the editor: '' = the default, else 0-10000 whole tickets. undefined = not valid. */
export function parseThresholdInput(text: string): number | null | undefined {
  const t = text.trim();
  if (t === '') return null;
  if (!/^\d{1,5}$/.test(t)) return undefined;
  const n = Number(t);
  return n <= 10000 ? n : undefined;
}

export interface LastCallStatus {
  active: boolean;
  remaining: number | null;
  threshold: number;
  thresholdSource: 'event' | 'org' | 'platform';
  eventThreshold: number | null;
  orgThreshold: number | null;
  platformThreshold: number;
  primary: SalePlatform;
  primaryUrl: string | null;
  canManage: boolean;
}

export function parseLastCallStatus(raw: unknown): LastCallStatus | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const src = r.threshold_source;
  return {
    active: r.active === true,
    remaining: intOrNull(r.remaining),
    threshold: intOrNull(r.threshold) ?? LAST_CALL_DEFAULT,
    thresholdSource: src === 'event' || src === 'org' ? src : 'platform',
    eventThreshold: intOrNull(r.event_threshold),
    orgThreshold: intOrNull(r.org_threshold),
    platformThreshold: intOrNull(r.platform_threshold) ?? LAST_CALL_DEFAULT,
    primary: platform(r.primary_source),
    primaryUrl: typeof r.primary_url === 'string' && r.primary_url.startsWith('https://') ? r.primary_url : null,
    canManage: r.can_manage === true,
  };
}

/** The dashboard badge: "Last call: selling only on Eventbrite (8 left)". */
export function lastCallText(s: Pick<LastCallStatus, 'primary' | 'remaining'>): string {
  const left = s.remaining === null ? '' : ` (${s.remaining} left)`;
  return `Last call: selling only on ${PLATFORM_LABEL[s.primary]}${left}`;
}

/** The settings line under the threshold. */
export function thresholdLine(s: LastCallStatus): string {
  if (s.threshold === 0) return 'Last call is off for this event: every channel sells until it sells out.';
  const from = s.thresholdSource === 'event' ? 'this event' : s.thresholdSource === 'org' ? 'your organization' : 'the default';
  return `At ${s.threshold} ticket${s.threshold === 1 ? '' : 's'} left (${from}), only ${PLATFORM_LABEL[s.primary]} sells: `
    + 'marketplace and S4K seats come back, and the other platforms show sold out.';
}

/** null before the migration. */
export async function fetchLastCallStatus(eventId: string): Promise<LastCallStatus | null> {
  const { data, error } = await supabase.rpc('exos_last_call_status', { p_event_id: eventId });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw error;
  }
  return parseLastCallStatus(data);
}

/** null = back to the org's / the platform's default; 0 = off. */
export async function setLastCallThreshold(eventId: string, threshold: number | null): Promise<LastCallStatus | null> {
  const { data, error } = await supabase.rpc('exos_set_last_call_threshold', { p_event_id: eventId, p_threshold: threshold });
  if (error) throw error;
  return parseLastCallStatus(data);
}

// --- The storefront (exos_public_event_sales, anon) -------------------------

export interface PublicSale {
  lastCall: boolean;
  sellsOn: SalePlatform;
  sellsOnUrl: string | null;
}

export function parsePublicSale(raw: unknown): PublicSale | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const url = typeof r.sells_on_url === 'string' && r.sells_on_url.startsWith('https://') ? r.sells_on_url : null;
  return { lastCall: r.last_call === true, sellsOn: platform(r.sells_on), sellsOnUrl: url };
}

/** Does Exos send this event's buyers elsewhere right now? */
export function sellsElsewhere(s: PublicSale | null): s is PublicSale {
  return !!s && s.lastCall && s.sellsOn !== 'exos';
}

/** null before the migration, or when the view can't be read. */
export async function fetchPublicSale(eventId: string): Promise<PublicSale | null> {
  const { data, error } = await supabase.from('exos_public_event_sales').select('*').eq('event_id', eventId).maybeSingle();
  if (error || !data) return null;
  return parsePublicSale(data);
}
