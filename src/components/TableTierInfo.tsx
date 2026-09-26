// Buyer side of a table package (mig 20260926050000): "Table for 6 · $1,000
// min spend · Mezzanine" plus the deposit per person. Renders nothing for a
// standard tier. Safe inside the tier <button> in EventDetails (inline only).
//
// One fetch per event (shared by every tier row on the page).

import { useEffect, useState } from 'react';
import { Users } from 'lucide-react';
import { getPublicTableTiers, type PublicTableTier } from '../lib/tablesApi';
import { depositPerPerson, tableSummary } from '../lib/tables';
import { formatCurrency } from '../lib/utils';

const cache = new Map<string, Promise<PublicTableTier[]>>();

function loadTables(eventId: string): Promise<PublicTableTier[]> {
  let p = cache.get(eventId);
  if (!p) {
    p = getPublicTableTiers(eventId).catch(() => {
      cache.delete(eventId);
      return [];
    });
    cache.set(eventId, p);
  }
  return p;
}

export default function TableTierInfo({
  eventId,
  tierId,
  price,
  currency = 'USD',
}: {
  eventId: string;
  tierId: string;
  /** Price per table the buyer pays (already all-in), for the per-person line. */
  price?: number;
  currency?: string;
}) {
  const [info, setInfo] = useState<PublicTableTier | null>(null);

  useEffect(() => {
    let live = true;
    loadTables(eventId).then((rows) => {
      if (live) setInfo(rows.find((r) => r.tierId === tierId) ?? null);
    });
    return () => {
      live = false;
    };
  }, [eventId, tierId]);

  if (!info) return null;
  const each = price && price > 0 ? depositPerPerson(price, info.partySize) : 0;
  return (
    <span className="flex flex-col gap-1 mb-3">
      <span className="inline-flex items-center gap-2 type text-[10px] uppercase tracking-widest text-brand-primary">
        <Users className="w-3 h-3" aria-hidden="true" />
        {tableSummary(info, currency)}
      </span>
      <span className="type text-[9px] text-white/40 uppercase tracking-widest">
        {info.partySize} tickets per table, all to you. Send them to your group.
        {each > 0 ? ` Deposit ${formatCurrency(each, currency)} per person.` : ''}
        {info.minSpendCents ? ' Minimum spend is paid at the venue.' : ''}
      </span>
    </span>
  );
}
