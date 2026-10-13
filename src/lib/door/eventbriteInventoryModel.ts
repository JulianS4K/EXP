// The Eventbrite inventory panel's data (mig 20261014110000), pure so vitest
// covers it; the calls are in ./eventbrite.

export interface EbTicketClassChoice {
  id: string;
  name: string | null;
  capacity: number | null;
  quantity_sold: number | null;
  inventory_tier_id: string | null;
  free: boolean;
  hidden: boolean;
}

export interface EbMapping {
  ebTicketClassId: string;
  ebTicketClassName: string | null;
  tierId: string;
  ebSold: number | null;
  ebCapacity: number | null;
  targetCapacity: number | null;
  pushedCapacity: number | null;
  pushedAt: string | null;
  plannedAt: string | null;
  oversold: number;
  lastReadAt: string | null;
  lastError: string | null;
}

export interface EbInventoryStatus {
  linked: boolean;
  writesEnabled: boolean;
  canSwitch: boolean;
  tiers: Array<{ id: string; name: string; capacity: number; sold: number }>;
  mappings: EbMapping[];
}

const numOrNull = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

export function parseInventoryStatus(raw: any): EbInventoryStatus {
  return {
    linked: raw?.linked === true,
    writesEnabled: raw?.writes_enabled === true,
    canSwitch: raw?.can_switch === true,
    tiers: (Array.isArray(raw?.tiers) ? raw.tiers : [])
      .filter((t: any) => typeof t?.id === 'string')
      .map((t: any) => ({ id: t.id, name: String(t.name ?? 'Ticket type'), capacity: Number(t.capacity) || 0, sold: Number(t.sold) || 0 })),
    mappings: (Array.isArray(raw?.mappings) ? raw.mappings : [])
      .filter((m: any) => typeof m?.eb_ticket_class_id === 'string' && typeof m?.tier_id === 'string')
      .map((m: any) => ({
        ebTicketClassId: m.eb_ticket_class_id,
        ebTicketClassName: m.eb_ticket_class_name ?? null,
        tierId: m.tier_id,
        ebSold: numOrNull(m.eb_sold),
        ebCapacity: numOrNull(m.eb_capacity),
        targetCapacity: numOrNull(m.target_capacity),
        pushedCapacity: numOrNull(m.pushed_capacity),
        pushedAt: m.pushed_at ?? null,
        plannedAt: m.planned_at ?? null,
        oversold: Number(m.oversold) || 0,
        lastReadAt: m.last_read_at ?? null,
        lastError: m.last_error ?? null,
      })),
  };
}

/** One line per mapping: what Eventbrite has, and what Exos would set or set. */
export function mappingLine(m: EbMapping, writesLive: boolean): string {
  if (m.lastError) return m.lastError;
  if (m.lastReadAt === null) return 'Counts after the next sync.';
  const left = m.targetCapacity !== null && m.ebSold !== null ? Math.max(m.targetCapacity - m.ebSold, 0) : null;
  const head = `${m.ebSold ?? 0} sold on Eventbrite`;
  if (m.targetCapacity === null || left === null) return head;
  if (m.ebCapacity === m.targetCapacity) return `${head} · ${left} left to sell there · in step`;
  return writesLive
    ? `${head} · setting its capacity to ${m.targetCapacity} (${left} left)`
    : `${head} · would set its capacity ${m.ebCapacity ?? '?'} → ${m.targetCapacity} (${left} left; not sent: sending is off)`;
}

