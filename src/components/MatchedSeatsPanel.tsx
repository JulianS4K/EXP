// MatchedSeatsPanel — matched seats for one event (mig 20261031210000,
// docs/matched-seats.md). Per ticket type: turn matching on, set group sizes,
// cutoff, reveal and the undersubscribed policy, list the spots (restaurants,
// bars) with their capacity, then after matching review the groups: move,
// swap, place leftovers, remove someone (optionally blocking them from that
// group), lock, reveal now, refund leftovers through exos-refund, and read
// reports. Owner / manager only (every call is checked in SQL).

import { useCallback, useEffect, useState } from 'react';
import { RefreshCw, Shuffle, Users } from 'lucide-react';
import type { Event } from '../types';
import { useToast } from '../context/ToastContext';
import {
  configBody, draftFromConfig, hoursLabel, LEFTOVER_REASON, refundBatches, type ConfigDraft,
} from '../lib/matchedSeats';
import {
  deleteSpot, getStaffViewOrNull, lockGroups, matchNow, moveMember, placeLeftover, removeMember, revealNow,
  reviewReport, setMatchConfig, swapMembers, upsertSpot, type StaffView,
} from '../lib/matchedSeatsApi';
import { refundOrder } from '../lib/refundsApi';

const input = 'border border-slate-200 rounded-lg px-2 py-1 text-sm w-full';

function when(ms: number | null): string {
  return ms ? new Date(ms).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '—';
}

function TierMatching({ tierId, tierName }: { tierId: string; tierName: string }) {
  const { toast } = useToast();
  const [view, setView] = useState<StaffView | null | undefined>(undefined);
  const [draft, setDraft] = useState<ConfigDraft>(draftFromConfig(null));
  const [spot, setSpot] = useState({ name: '', address: '', details: '', capacity: '' });
  const [busy, setBusy] = useState(false);
  const [picked, setPicked] = useState<string | null>(null);   // member id picked for a swap

  const load = useCallback(async () => {
    try {
      const v = await getStaffViewOrNull(tierId);
      setView(v);
      if (v) setDraft(draftFromConfig(v.config));
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not load matched seats.' });
      setView(null);
    }
  }, [tierId, toast]);
  useEffect(() => { void load(); }, [load]);

  const run = async (fn: () => Promise<unknown>, ok?: string) => {
    setBusy(true);
    try {
      await fn();
      if (ok) toast({ kind: 'success', message: ok });
      await load();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Something went wrong.' });
    } finally {
      setBusy(false);
    }
  };

  if (view === undefined) return null;
  const open = !view || view.config.status === 'open';
  const set = (patch: Partial<ConfigDraft>) => setDraft((d) => ({ ...d, ...patch }));
  const spotName = (id: string | null) => view?.spots.find((s) => s.id === id)?.name ?? '—';
  const unrevealed = (view?.groups ?? []).filter((g) => g.status === 'draft' || g.status === 'locked');
  const refunds = refundBatches(view?.leftovers ?? []);

  return (
    <div className="border border-slate-100 rounded-xl p-4 mb-4">
      <div className="flex items-center justify-between mb-3">
        <p className="font-bold text-slate-900">{tierName}</p>
        {view && (
          <span className="text-xs text-slate-500">
            {view.config.status} · {view.holders} holders · {view.answered} answered the quiz ·
            matches {when(view.config.matchAt)} · reveals {when(view.config.revealAt)}
          </span>
        )}
      </div>

      {/* Settings */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 text-xs text-slate-600">
        <label>Smallest group<input className={input} disabled={!open} value={draft.groupMin} onChange={(e) => set({ groupMin: e.target.value })} /></label>
        <label>Ideal group<input className={input} disabled={!open} value={draft.groupTarget} onChange={(e) => set({ groupTarget: e.target.value })} /></label>
        <label>Largest group<input className={input} disabled={!open} value={draft.groupMax} onChange={(e) => set({ groupMax: e.target.value })} /></label>
        <label>Number of groups (blank = derive)<input className={input} disabled={!open} value={draft.groupCount} onChange={(e) => set({ groupCount: e.target.value })} /></label>
        <label>Match, hours before ({hoursLabel(Number(draft.matchHoursBefore) || 0)})<input className={input} disabled={!open} value={draft.matchHoursBefore} onChange={(e) => set({ matchHoursBefore: e.target.value })} /></label>
        <label>Reveal, hours before ({hoursLabel(Number(draft.revealHoursBefore) || 0)})<input className={input} value={draft.revealHoursBefore} onChange={(e) => set({ revealHoursBefore: e.target.value })} /></label>
        <label>Too-small groups
          <select className={input} disabled={!open} value={draft.undersubPolicy}
            onChange={(e) => set({ undersubPolicy: e.target.value === 'refund' ? 'refund' : 'merge' })}>
            <option value="merge">Merge into other groups</option>
            <option value="refund">Refund the leftovers</option>
          </select>
        </label>
        <label>Keep quiz answers (days after)<input className={input} value={draft.retentionDays} onChange={(e) => set({ retentionDays: e.target.value })} /></label>
        <label className="col-span-2">Interests to pick from (comma separated)<input className={input} value={draft.quizTags} onChange={(e) => set({ quizTags: e.target.value })} /></label>
        <label>Languages (en, es)<input className={input} value={draft.quizLanguages} onChange={(e) => set({ quizLanguages: e.target.value })} /></label>
        <label className="flex items-end gap-2"><input type="checkbox" checked={draft.quizEnabled} onChange={(e) => set({ quizEnabled: e.target.checked })} /> Ask the quiz</label>
      </div>
      <button type="button" disabled={busy} className="mt-3 bg-slate-900 text-white text-xs font-bold px-4 py-2 rounded-lg"
        onClick={() => {
          let body: Record<string, unknown>;
          try { body = configBody(draft); } catch (e: any) { toast({ kind: 'error', message: e.message }); return; }
          void run(() => setMatchConfig(tierId, body), view ? 'Saved.' : 'Matched seats on for this ticket type.');
        }}>
        {view ? 'Save settings' : 'Sell as matched seats'}
      </button>

      {view && (
        <>
          {/* Spots */}
          <p className="mt-5 text-xs font-bold uppercase tracking-widest text-slate-400">Spots</p>
          <ul className="text-sm divide-y divide-slate-100">
            {view.spots.map((s) => (
              <li key={s.id} className="py-2 flex items-center justify-between gap-2">
                <span className={s.active ? '' : 'line-through text-slate-400'}>
                  <b>{s.name}</b> · {s.capacity} seats{s.address ? ` · ${s.address}` : ''}
                </span>
                <span className="flex gap-3 text-xs">
                  <button type="button" disabled={busy} className="text-slate-500 underline"
                    onClick={() => void run(() => upsertSpot(tierId, { id: s.id, active: !s.active }))}>
                    {s.active ? 'Turn off' : 'Turn on'}
                  </button>
                  <button type="button" disabled={busy} className="text-rose-600 underline"
                    onClick={() => void run(() => deleteSpot(s.id))}>Delete</button>
                </span>
              </li>
            ))}
          </ul>
          {view.spots.reduce((n, s) => n + (s.active ? s.capacity : 0), 0) < view.holders && (
            <p className="text-xs text-amber-700 mt-1">The spots seat fewer people than hold tickets.</p>
          )}
          <div className="grid grid-cols-2 md:grid-cols-5 gap-2 mt-2">
            <input className={input} placeholder="Name" value={spot.name} onChange={(e) => setSpot({ ...spot, name: e.target.value })} />
            <input className={input} placeholder="Address" value={spot.address} onChange={(e) => setSpot({ ...spot, address: e.target.value })} />
            <input className={input} placeholder="Note for guests" value={spot.details} onChange={(e) => setSpot({ ...spot, details: e.target.value })} />
            <input className={input} placeholder="Seats" value={spot.capacity} onChange={(e) => setSpot({ ...spot, capacity: e.target.value })} />
            <button type="button" disabled={busy || !spot.name.trim()} className="bg-slate-100 text-slate-800 text-xs font-bold rounded-lg"
              onClick={() => void run(async () => {
                await upsertSpot(tierId, { name: spot.name, address: spot.address, details: spot.details, capacity: Number(spot.capacity) });
                setSpot({ name: '', address: '', details: '', capacity: '' });
              }, 'Spot added.')}>Add spot</button>
          </div>

          {/* Matching */}
          <div className="flex flex-wrap gap-2 mt-5">
            <button type="button" disabled={busy || view.config.status === 'revealed' || unrevealed.some((g) => g.status === 'locked')}
              className="bg-brand-primary text-black text-xs font-bold px-4 py-2 rounded-lg flex items-center gap-1"
              onClick={() => void run(async () => {
                const r = await matchNow(tierId, false);
                toast({ kind: r.warnings.length ? 'warn' : 'success',
                  message: `${r.groups} groups, ${r.placed} seated, ${r.leftovers} left over.${r.warnings.length ? ' ' + r.warnings.join('; ') : ''}` });
              })}>
              <Users className="w-3.5 h-3.5" /> Match now
            </button>
            {!open && (
              <>
                <button type="button" disabled={busy || unrevealed.length === 0 || unrevealed.some((g) => g.status === 'locked')}
                  className="bg-slate-100 text-xs font-bold px-4 py-2 rounded-lg flex items-center gap-1"
                  onClick={() => void run(() => matchNow(tierId, true), 'Re-matched with a new seed.')}>
                  <Shuffle className="w-3.5 h-3.5" /> Reshuffle
                </button>
                <button type="button" disabled={busy || unrevealed.length === 0} className="bg-slate-100 text-xs font-bold px-4 py-2 rounded-lg"
                  onClick={() => {
                    const locked = unrevealed.some((g) => g.status === 'locked');
                    void run(() => lockGroups(tierId, !locked), locked ? 'Unlocked.' : 'Locked: a re-run can\'t change them.');
                  }}>
                  {unrevealed.some((g) => g.status === 'locked') ? 'Unlock' : 'Lock after review'}
                </button>
                <button type="button" disabled={busy} className="bg-slate-900 text-white text-xs font-bold px-4 py-2 rounded-lg"
                  onClick={() => {
                    if (!window.confirm('Send every member their spot, time and group now?')) return;
                    void run(async () => { const n = await revealNow(tierId); toast({ kind: 'success', message: `${n} notified.` }); });
                  }}>Reveal now</button>
              </>
            )}
            <button type="button" className="text-xs text-slate-500 flex items-center gap-1" onClick={() => void load()}>
              <RefreshCw className="w-3.5 h-3.5" /> Refresh
            </button>
          </div>

          {/* Groups */}
          {view.groups.map((g) => (
            <div key={g.id} className="mt-4 border border-slate-100 rounded-lg p-3">
              <p className="text-sm font-bold text-slate-800">
                {g.label} · {spotName(g.spotId)} · {when(g.meetAt)} · {g.status}
                {g.score != null && <span className="font-normal text-slate-400"> · fit {g.score}</span>}
              </p>
              <ul className="text-sm mt-2 space-y-1">
                {g.members.map((m) => (
                  <li key={m.id} className={`flex items-center justify-between gap-2 ${m.status !== 'active' ? 'text-slate-400' : ''}`}>
                    <span>
                      {m.firstName}
                      <span className="text-xs text-slate-400">
                        {[m.ageBand, m.language, m.tags.join('/'), m.partyCode && `party ${m.partyCode}`].filter(Boolean).join(' · ')}
                        {m.status !== 'active' && ` · ${m.status}${m.removedReason ? `: ${m.removedReason}` : ''}`}
                      </span>
                    </span>
                    {m.status === 'active' && (
                      <span className="flex gap-3 text-xs">
                        {(g.status === 'draft' || g.status === 'locked') && (
                          picked && picked !== m.id ? (
                            <button type="button" disabled={busy} className="text-brand-primary underline"
                              onClick={() => { const a = picked; setPicked(null); void run(() => swapMembers(a, m.id), 'Swapped.'); }}>Swap here</button>
                          ) : (
                            <button type="button" disabled={busy} className="text-slate-500 underline"
                              onClick={() => setPicked(picked === m.id ? null : m.id)}>{picked === m.id ? 'Cancel swap' : 'Swap'}</button>
                          )
                        )}
                        <button type="button" disabled={busy} className="text-rose-600 underline"
                          onClick={() => {
                            const why = window.prompt(`Remove ${m.firstName} from ${g.label}? Reason (staff only):`);
                            if (why === null) return;
                            const block = window.confirm(`Also never group ${m.firstName} with the others here again?`);
                            void run(() => removeMember(m.id, why, block), 'Removed.');
                          }}>Remove</button>
                      </span>
                    )}
                  </li>
                ))}
              </ul>
              {picked && !g.members.some((m) => m.id === picked) && (g.status === 'draft' || g.status === 'locked') && (
                <button type="button" disabled={busy} className="mt-2 text-xs text-brand-primary underline"
                  onClick={() => { const a = picked; setPicked(null); void run(() => moveMember(g.id, a), 'Moved.'); }}>
                  Move the picked person here
                </button>
              )}
            </div>
          ))}

          {/* Leftovers */}
          {view.leftovers.length > 0 && (
            <div className="mt-4">
              <p className="text-xs font-bold uppercase tracking-widest text-slate-400">Not in a group</p>
              <ul className="text-sm mt-1 space-y-1">
                {view.leftovers.map((l) => (
                  <li key={l.ticketId} className="flex items-center justify-between gap-2">
                    <span>{l.firstName} <span className="text-xs text-slate-400">{LEFTOVER_REASON[l.reason] ?? l.reason} · {l.status}</span></span>
                    {l.status === 'active' && unrevealed.length > 0 && (
                      <select className="text-xs border border-slate-200 rounded" defaultValue=""
                        onChange={(e) => { const gid = e.target.value; if (gid) void run(() => placeLeftover(gid, l.ticketId), 'Placed.'); }}>
                        <option value="">Place in…</option>
                        {unrevealed.map((g) => <option key={g.id} value={g.id}>{g.label}</option>)}
                      </select>
                    )}
                  </li>
                ))}
              </ul>
              {refunds.length > 0 && (
                <button type="button" disabled={busy} className="mt-2 bg-rose-600 text-white text-xs font-bold px-4 py-2 rounded-lg"
                  onClick={() => {
                    if (!window.confirm(`Refund ${refunds.reduce((n, r) => n + r.ticketIds.length, 0)} paid leftover tickets in full?`)) return;
                    void run(async () => {
                      for (const r of refunds) {
                        await refundOrder({
                          sessionId: r.sessionId, nonce: `match:${tierId}:${r.sessionId}`.slice(0, 200),
                          reason: 'Matched seats: no group', items: r.ticketIds.map((ticketId) => ({ ticketId })),
                        });
                      }
                    }, 'Refunds sent.');
                  }}>Refund paid leftovers</button>
              )}
            </div>
          )}

          {/* Reports */}
          {view.reports.length > 0 && (
            <div className="mt-4">
              <p className="text-xs font-bold uppercase tracking-widest text-slate-400">Reports</p>
              <ul className="text-sm mt-1 space-y-2">
                {view.reports.map((r) => (
                  <li key={r.id} className="border border-slate-100 rounded p-2">
                    <p><b>{r.memberFirstName ?? 'A member'}</b> · {r.reason} · {r.status} · {when(r.createdAt)}</p>
                    {r.details && <p className="text-slate-600">{r.details}</p>}
                    {r.status === 'open' && (
                      <span className="flex gap-3 text-xs mt-1">
                        {['reviewed', 'actioned', 'dismissed'].map((s) => (
                          <button key={s} type="button" disabled={busy} className="text-slate-500 underline"
                            onClick={() => void run(() => reviewReport(r.id, s))}>{s}</button>
                        ))}
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}
    </div>
  );
}

export default function MatchedSeatsPanel({ event, canManage }: { event: Event; canManage: boolean }) {
  const tiers = event.ticketTiers ?? [];
  if (!canManage || tiers.length === 0) return null;
  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-8">
      <h3 className="text-lg font-black text-slate-900 flex items-center gap-2 mb-1">
        <Users className="w-5 h-5" /> Matched seats
      </h3>
      <p className="text-sm text-slate-500 mb-4">
        Sell seats instead of known tables: Exos groups the buyers at the cutoff, you review, and each guest learns
        their spot, the time and the others' first names at reveal time.
      </p>
      {tiers.map((t) => <div key={t.id}><TierMatching tierId={t.id} tierName={t.name} /></div>)}
    </div>
  );
}
