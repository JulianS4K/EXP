// Auto split of each ticket type across the marketplaces (mig 20261014090000):
// Exos keeps a reserve (10%, at least one pack, down to one pack 48 hours
// before the show) and shares the rest evenly, rebalanced daily, then every
// 6 hours, then hourly. Free ticket types stay on Exos. Defaults from
// docs/marketplace/channel-sim.md. Pure (no Supabase); the RPCs are in ./channelSplit.


export type SplitMode = 'auto' | 'manual';

export interface SplitTier { tierId: string; unsold: number; reserve: number; shares: Record<string, number> }
export interface ChannelSplit {
  mode: SplitMode;
  reservePct: number;
  taperHours: number;
  tapered: boolean;
  lastRunAt: string | null;
  tiers: SplitTier[];
}

export function parseChannelSplit(raw: any): ChannelSplit {
  return {
    mode: raw?.mode === 'auto' ? 'auto' : 'manual',
    reservePct: Number.isFinite(Number(raw?.reserve_pct)) ? Number(raw.reserve_pct) : 10,
    taperHours: Number.isFinite(Number(raw?.taper_hours)) ? Number(raw.taper_hours) : 48,
    tapered: raw?.tapered === true,
    lastRunAt: typeof raw?.last_run_at === 'string' ? raw.last_run_at : null,
    tiers: Array.isArray(raw?.tiers)
      ? raw.tiers.map((t: any) => ({
        tierId: String(t?.tier_id ?? ''),
        unsold: Number(t?.unsold) || 0,
        reserve: Number(t?.reserve) || 0,
        shares: Object.fromEntries(Object.entries(t?.shares ?? {}).map(([k, v]) => [k, Number(v) || 0])),
      }))
      : [],
  };
}

/** One line on what the auto split does right now. */
export function describeSplit(s: Pick<ChannelSplit, 'reservePct' | 'taperHours' | 'tapered'>): string {
  const hours = s.taperHours === 48 ? '48 hours' : `${s.taperHours} hour${s.taperHours === 1 ? '' : 's'}`;
  return s.tapered
    ? `Inside the last ${hours}: Exos keeps one pack (your max per order) and the marketplaces share the rest.`
    : `Exos keeps ${s.reservePct}% (at least one pack); the rest is shared evenly. ${hours[0].toUpperCase()}${hours.slice(1)} before the show it drops to one pack.`;
}

