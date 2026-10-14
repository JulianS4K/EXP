// Attendee lookup in Eventbrite's words (exos_attendee_lookup, mig
// 20261014120000). Exos tickets and every guest (Eventbrite, CSV imports,
// guest lists) answer to the same four statuses, so an organizer finds a
// person the same way whichever platform sold the ticket. Pure (the RPC
// call: ./attendeeLookupApi).

export const STATUS_WORDS = ['Attending', 'Checked In', 'Not Attending', 'Transferred'] as const;
export type StatusWord = (typeof STATUS_WORDS)[number];

export interface LookupRow {
  source: string;
  name: string;
  email: string | null;
  ticket: string | null;
  status: StatusWord | null;
  /** Exos's own state, or Eventbrite's word for an Eventbrite attendee. */
  detail: string | null;
  refunded: boolean;
  checkedInAt: string | null;
  checkedInOn: 'exos' | 'eventbrite' | 'both' | null;
  codeStatus: 'unused' | 'used' | 'refunded' | null;
  ref: string;
  channel: string;
}

export interface LookupResult {
  counts: Partial<Record<StatusWord, number>>;
  rows: LookupRow[];
}

const isWord = (s: unknown): s is StatusWord => typeof s === 'string' && (STATUS_WORDS as readonly string[]).includes(s);
const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

export function parseLookup(raw: any): LookupResult {
  const counts: LookupResult['counts'] = {};
  if (raw?.counts && typeof raw.counts === 'object') {
    for (const [k, v] of Object.entries(raw.counts)) if (isWord(k)) counts[k] = Number(v) || 0;
  }
  const rows: LookupRow[] = (Array.isArray(raw?.rows) ? raw.rows : []).map((r: any) => ({
    source: str(r?.source) ?? 'Exos',
    name: str(r?.name) ?? '(no name)',
    email: str(r?.email),
    ticket: str(r?.ticket),
    status: isWord(r?.status) ? r.status : null,
    detail: str(r?.detail),
    refunded: r?.refunded === true,
    checkedInAt: str(r?.checked_in_at),
    checkedInOn: r?.checked_in_on === 'exos' || r?.checked_in_on === 'eventbrite' || r?.checked_in_on === 'both'
      ? r.checked_in_on : null,
    codeStatus: r?.code_status === 'unused' || r?.code_status === 'used' || r?.code_status === 'refunded'
      ? r.code_status : null,
    ref: str(r?.ref) ?? '',
    channel: str(r?.channel) ?? 'exos',
  }));
  return { counts, rows };
}

/** Where a checked-in person was let in. */
export function checkedInOnText(on: LookupRow['checkedInOn']): string {
  switch (on) {
    case 'exos': return 'at the Exos door';
    case 'eventbrite': return "on Eventbrite's app";
    case 'both': return "at the Exos door and on Eventbrite's app";
    default: return '';
  }
}

/** The status word, with "refunded" when it's why they're not attending. */
export function statusLabel(r: Pick<LookupRow, 'status' | 'refunded'>): string {
  if (!r.status) return 'Unknown';
  return r.status === 'Not Attending' && r.refunded ? 'Not Attending (refunded)' : r.status;
}
