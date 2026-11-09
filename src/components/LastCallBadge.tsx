// The event dashboard's "Last call: selling only on <primary>" line (mig
// 20261029100000). Shows nothing outside last call or before the migration.

import { useEffect, useState } from 'react';
import { Hourglass } from 'lucide-react';
import { fetchLastCallStatus, lastCallText, type LastCallStatus } from '../lib/marketplace/lastCall';

export default function LastCallBadge({ eventId }: { eventId: string }) {
  const [st, setSt] = useState<LastCallStatus | null>(null);
  useEffect(() => {
    let live = true;
    fetchLastCallStatus(eventId).then((s) => { if (live) setSt(s); }).catch(() => undefined);
    return () => { live = false; };
  }, [eventId]);
  if (!st?.active) return null;
  return (
    <div role="status" className="mb-6 inline-flex items-center gap-2 border border-amber-300 bg-amber-50 px-4 py-2 text-xs font-bold text-amber-800">
      <Hourglass size={14} aria-hidden="true" />
      <span>{lastCallText(st)}</span>
      {st.primaryUrl && (
        <a href={st.primaryUrl} target="_blank" rel="noopener noreferrer" className="underline font-normal">open it</a>
      )}
    </div>
  );
}
