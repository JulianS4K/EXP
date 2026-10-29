// Fixed block (mig 20261029160000): the organizer sells on a platform Exos
// can't sync (DICE, Shotgun, RA, a box office) and gives Exos a block of
// tickets per type to sell. The block is the ticket type's capacity. At the
// release time (default 24 hours before doors) Exos stops selling it and says
// how many of each type go back on that platform. The server decides
// (exos_fixed_block_status / exos_set_fixed_block / exos_release_fixed_block_now);
// this parses and words it.

import { supabase } from '../supabase';
import { isMissingRpc } from '../door/net';

/** Names the editor suggests (free text is fine). */
export const BLOCK_PLATFORMS = ['DICE', 'Shotgun', 'RA', 'Posh', 'Tixr', 'Box office'];

export const BLOCK_MAX = 100000;
export const DEFAULT_RELEASE_HOURS = 24;

export interface BlockTier {
  tierId: string;
  name: string;
  table: boolean;
  partySize: number | null;
  block: number;
  sold: number;
  left: number;
  /** Once released: what the release sent back, what is free now, and the difference (put back too). */
  returned: number | null;
  unsoldNow: number | null;
  moreToReturn: number | null;
}

export interface BlockRelease {
  releasedAt: Date;
  reason: 'scheduled' | 'manual';
  platform: string;
  totalReturned: number;
  totalPending: number;
  mailed: number;
}

export interface FixedBlockStatus {
  on: boolean;
  /** exos | eventbrite | luma | external */
  primarySource: string;
  platform: string | null;
  platformUrl: string | null;
  releaseAt: Date | null;
  releaseAtSet: Date | null;
  releaseAtDefault: Date | null;
  releasedAt: Date | null;
  release: BlockRelease | null;
  tiers: BlockTier[];
  totals: { block: number; sold: number; left: number; moreToReturn: number | null };
  totalTickets: number;
  cancelled: boolean;
  canManage: boolean;
}

const int = (v: unknown, d = 0): number => (typeof v === 'number' && Number.isFinite(v) ? Math.trunc(v) : d);
const intOrNull = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? Math.trunc(v) : null);
const date = (v: unknown): Date | null => {
  if (typeof v !== 'string') return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
};
const text = (v: unknown): string | null => (typeof v === 'string' && v.trim() !== '' ? v : null);

export function parseFixedBlockStatus(raw: unknown): FixedBlockStatus | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const rel = r.release && typeof r.release === 'object' ? (r.release as Record<string, unknown>) : null;
  const totals = r.totals && typeof r.totals === 'object' ? (r.totals as Record<string, unknown>) : {};
  const url = text(r.platform_url);
  const releasedAt = rel ? date(rel.released_at) : null;
  return {
    on: r.on === true,
    primarySource: typeof r.primary_source === 'string' ? r.primary_source : 'exos',
    platform: text(r.platform),
    platformUrl: url && url.startsWith('https://') ? url : null,
    releaseAt: date(r.release_at),
    releaseAtSet: date(r.release_at_set),
    releaseAtDefault: date(r.release_at_default),
    releasedAt: date(r.released_at),
    release: rel && releasedAt ? {
      releasedAt,
      reason: rel.reason === 'manual' ? 'manual' : 'scheduled',
      platform: text(rel.platform) ?? text(r.platform) ?? 'the other platform',
      totalReturned: int(rel.total_returned),
      totalPending: int(rel.total_pending),
      mailed: int(rel.mailed),
    } : null,
    tiers: (Array.isArray(r.tiers) ? r.tiers : []).filter((t): t is Record<string, unknown> => !!t && typeof t === 'object')
      .map((t) => ({
        tierId: String(t.tier_id ?? ''),
        name: text(t.name) ?? 'Ticket',
        table: t.kind === 'table',
        partySize: intOrNull(t.party_size),
        block: int(t.block),
        sold: int(t.sold),
        left: int(t.left),
        returned: intOrNull(t.returned),
        unsoldNow: intOrNull(t.unsold_now),
        moreToReturn: intOrNull(t.more_to_return),
      })),
    totals: { block: int(totals.block), sold: int(totals.sold), left: int(totals.left), moreToReturn: intOrNull(totals.more_to_return) },
    totalTickets: int(r.total_tickets),
    cancelled: r.cancelled === true,
    canManage: r.can_manage === true,
  };
}

/** A block typed into the editor: a whole number 1-100000, at least what the type has sold. undefined = not valid. */
export function parseBlockInput(input: string, sold = 0): number | undefined {
  const t = input.trim();
  if (!/^\d{1,6}$/.test(t)) return undefined;
  const n = Number(t);
  return n >= 1 && n <= BLOCK_MAX && n >= sold ? n : undefined;
}

/** "95 tickets", "1 table of 6". */
export function blockUnits(n: number, t: Pick<BlockTier, 'table' | 'partySize'>): string {
  if (t.table) return `${n} table${n === 1 ? '' : 's'}${t.partySize && t.partySize > 1 ? ` of ${t.partySize}` : ''}`;
  return `${n} ticket${n === 1 ? '' : 's'}`;
}

/** The default release: 24 hours before doors (else the start). */
export function defaultReleaseAt(doorsAt: Date | null, startsAt: Date | null): Date | null {
  const base = doorsAt ?? startsAt;
  return base ? new Date(base.getTime() - DEFAULT_RELEASE_HOURS * 3600_000) : null;
}

/** A Date as a datetime-local value (the viewer's zone). */
export function toLocalInput(d: Date | null): string {
  if (!d) return '';
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** A datetime-local value back to a Date; '' = the default (null); undefined = not valid. */
export function fromLocalInput(v: string): Date | null | undefined {
  const s = v.trim();
  if (s === '') return null;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(s)) return undefined;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? undefined : d;
}

/** The dashboard line. */
export function blockLine(s: FixedBlockStatus): string {
  const platform = s.platform ?? 'the other platform';
  if (s.release) {
    const more = s.totals.moreToReturn ?? 0;
    return `Block released to ${platform}: put ${s.release.totalReturned} back on sale there`
      + (more > 0 ? `, and ${more} more that came back since` : '')
      + `. Exos sold ${s.totals.sold} of ${s.totals.block}.`;
  }
  return `Selling a block of ${s.totals.block} for ${platform}: ${s.totals.sold} sold, ${s.totals.left} left.`;
}

// ── Calls ───────────────────────────────────────────────────────────────

const rpcMsg = (e: { message?: string }) => new Error((e.message ?? 'Not saved.').replace(/^exos_\w+: /, ''));

/** null before the migration. */
export async function fetchFixedBlockStatus(eventId: string): Promise<FixedBlockStatus | null> {
  const { data, error } = await supabase.rpc('exos_fixed_block_status', { p_event_id: eventId });
  if (error) {
    if (isMissingRpc(error)) return null;
    throw rpcMsg(error);
  }
  return parseFixedBlockStatus(data);
}

export interface FixedBlockInput {
  platform: string;
  platformUrl: string | null;
  /** ticket type id → block size (its own units: tables for a table type) */
  blocks: Record<string, number>;
  /** null = 24 hours before doors */
  releaseAt: Date | null;
}

export async function setFixedBlock(eventId: string, input: FixedBlockInput | null): Promise<FixedBlockStatus | null> {
  const { data, error } = await supabase.rpc('exos_set_fixed_block', input
    ? {
      p_event_id: eventId, p_on: true, p_platform: input.platform, p_platform_url: input.platformUrl,
      p_blocks: input.blocks, p_release_at: input.releaseAt ? input.releaseAt.toISOString() : null,
    }
    : { p_event_id: eventId, p_on: false });
  if (error) throw rpcMsg(error);
  return parseFixedBlockStatus(data);
}

export async function releaseFixedBlockNow(eventId: string): Promise<FixedBlockStatus | null> {
  const { data, error } = await supabase.rpc('exos_release_fixed_block_now', { p_event_id: eventId });
  if (error) throw rpcMsg(error);
  return parseFixedBlockStatus(data);
}
