// The event dashboard's fixed-block line (mig 20261029160000): block sold /
// left and the release time, then what to put back on the other platform.
// Shows nothing for an event that doesn't sell a block, or before the migration.

import { useEffect, useState } from 'react';
import { Boxes } from 'lucide-react';
import { blockLine, blockUnits, fetchFixedBlockStatus, type FixedBlockStatus } from '../lib/marketplace/fixedBlock';

const when = (d: Date | null) => (d ? d.toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');

export default function FixedBlockSummary({ eventId }: { eventId: string }) {
  const [st, setSt] = useState<FixedBlockStatus | null>(null);
  useEffect(() => {
    let live = true;
    fetchFixedBlockStatus(eventId).then((s) => { if (live) setSt(s); }).catch(() => undefined);
    return () => { live = false; };
  }, [eventId]);
  if (!st || (!st.on && !st.release)) return null;
  const released = !!st.release;
  return (
    <div role="status" className={`mb-6 border px-4 py-3 text-xs ${released ? 'border-amber-300 bg-amber-50 text-amber-900' : 'border-slate-200 bg-white text-slate-700'}`}>
      <div className="flex items-center gap-2 font-bold">
        <Boxes size={14} aria-hidden="true" />
        <span>{blockLine(st)}</span>
        {st.platformUrl && (
          <a href={st.platformUrl} target="_blank" rel="noopener noreferrer" className="underline font-normal">open {st.platform}</a>
        )}
      </div>
      {!released && st.releaseAt && (
        <p className="mt-1">Unsold block tickets go back to {st.platform} {when(st.releaseAt)}.</p>
      )}
      <table className="mt-2">
        <tbody>
          {st.tiers.map((t) => (
            <tr key={t.tierId}>
              <td className="pr-4">{t.name}</td>
              <td className="pr-4">sold {t.sold} of {t.block}</td>
              {released
                ? <td className="pr-4 font-bold">put back {blockUnits((t.returned ?? 0) + (t.moreToReturn ?? 0), t)}</td>
                : <td className="pr-4">{blockUnits(t.left, t)} left</td>}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
