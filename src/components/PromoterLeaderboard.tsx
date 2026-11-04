// PromoterLeaderboard — the org's street team ranked by tickets, on the
// promoter's own page /p/:token (mig 20261102150000,
// exos_promoter_leaderboard: token-gated, names and ticket counts only, no
// money). All time or one event. Hidden when the database doesn't have it.

import { useEffect, useState } from 'react';
import { Trophy } from 'lucide-react';
import { promoterLeaderboard, type LeaderboardEntry } from '../lib/promoters';

export default function PromoterLeaderboard({ token, events }: {
  token: string;
  events: { event_id: string; name: string }[];
}) {
  const [eventId, setEventId] = useState('');
  const [board, setBoard] = useState<{ promoters: number; rows: LeaderboardEntry[] } | null>(null);

  useEffect(() => {
    let live = true;
    promoterLeaderboard(token, eventId || undefined).then((b) => { if (live) setBoard(b); }).catch(() => {});
    return () => { live = false; };
  }, [token, eventId]);

  if (!board || board.promoters < 2) return null;
  return (
    <section className="bg-[#111] border border-white/10 p-4 mb-8">
      <div className="flex flex-wrap items-center justify-between gap-2 mb-3">
        <p className="type text-[10px] uppercase tracking-widest text-brand-primary flex items-center gap-2">
          <Trophy className="w-3 h-3" /> Leaderboard
        </p>
        {events.length > 0 && (
          <select aria-label="Leaderboard for" value={eventId} onChange={(e) => setEventId(e.target.value)}
            className="bg-black border border-white/20 px-2 py-1 text-[11px] text-white">
            <option value="">All events</option>
            {events.map((e) => <option key={e.event_id} value={e.event_id}>{e.name}</option>)}
          </select>
        )}
      </div>
      <ol className="divide-y divide-white/10">
        {board.rows.map((r) => (
          <li key={`${r.rank}-${r.name}-${r.me}`} className={`flex items-center gap-3 py-2 text-sm ${r.me ? 'text-brand-primary' : 'text-white/80'}`}>
            <span className="disp w-8 text-white/40">{r.rank}</span>
            <span className="flex-1 truncate">{r.name}{r.me ? ' (you)' : ''}</span>
            <span className="type text-[11px]">{r.tickets} ticket{r.tickets === 1 ? '' : 's'}</span>
          </li>
        ))}
      </ol>
    </section>
  );
}
