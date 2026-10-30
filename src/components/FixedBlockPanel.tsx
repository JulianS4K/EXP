// Edit event → Selling a block for another platform (mig 20261029160000).
// The organizer sells on DICE (or any platform Exos can't sync), lowers its
// capacity there by N and gives Exos a block of N per ticket type. Exos sells
// the block on its own channels and, at the release time (default 24 hours
// before doors), stops and says how many go back on the other platform.

import { useCallback, useEffect, useState } from 'react';
import { Boxes } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  BLOCK_PLATFORMS, blockLine, blockUnits, fetchFixedBlockStatus, fromLocalInput, parseBlockInput, releaseFixedBlockNow,
  setFixedBlock, toLocalInput, type FixedBlockStatus,
} from '../lib/marketplace/fixedBlock';

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const FLD = 'bg-black border border-white/20 px-3 py-2 text-xs text-white';
const LBL = 'type block text-[10px] uppercase tracking-widest text-white/50 mb-1';

const when = (d: Date | null) => (d ? d.toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');

export default function FixedBlockPanel({ eventId, onBlocks }: {
  eventId: string;
  /** The saved blocks (ticket type id → capacity), so the editor's own copy doesn't save over them. */
  onBlocks?: (blocks: Record<string, number>) => void;
}) {
  const { toast } = useToast();
  const [st, setSt] = useState<FixedBlockStatus | null>(null);
  const [hidden, setHidden] = useState(false);
  const [editing, setEditing] = useState(false);
  const [platform, setPlatform] = useState('');
  const [url, setUrl] = useState('');
  const [blocks, setBlocks] = useState<Record<string, string>>({});
  const [release, setRelease] = useState('');
  const [busy, setBusy] = useState(false);

  const show = useCallback((s: FixedBlockStatus | null) => {
    if (!s) { setHidden(true); return; }
    setSt(s);
    setPlatform(s.platform ?? '');
    setUrl(s.platformUrl ?? '');
    setBlocks(Object.fromEntries(s.tiers.map((t) => [t.tierId, t.block > 0 ? String(t.block) : ''])));
    setRelease(toLocalInput(s.releaseAtSet));
    setEditing(false);
  }, []);
  useEffect(() => {
    fetchFixedBlockStatus(eventId).then(show).catch(() => setHidden(true));
  }, [eventId, show]);
  if (hidden || !st) return null;

  const parsed = st.tiers.map((t) => ({ t, n: parseBlockInput(blocks[t.tierId] ?? '', t.sold) }));
  const rel = fromLocalInput(release);
  const valid = platform.trim().length > 0 && platform.trim().length <= 60 && parsed.length > 0
    && parsed.every((p) => p.n !== undefined) && rel !== undefined
    && (url.trim() === '' || /^https:\/\/[^\s/]+\.[^\s]+$/.test(url.trim()));
  const formOpen = st.canManage && !st.release && (st.on || editing);

  const run = async (fn: () => Promise<FixedBlockStatus | null>, ok: string) => {
    setBusy(true);
    try {
      const s = await fn();
      show(s);
      if (s) onBlocks?.(Object.fromEntries(s.tiers.map((t) => [t.tierId, t.block])));
      toast({ kind: 'success', message: ok });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Not saved.' });
    } finally {
      setBusy(false);
    }
  };
  const save = () => {
    if (!valid) return;
    void run(() => setFixedBlock(eventId, {
      platform: platform.trim(),
      platformUrl: url.trim() || null,
      blocks: Object.fromEntries(parsed.map((p) => [p.t.tierId, p.n as number])),
      releaseAt: rel ?? null,
    }), 'Block saved.');
  };
  const releaseNow = () => {
    if (typeof window !== 'undefined' && !window.confirm(
      `Stop selling the block on Exos now and hand the unsold tickets back to ${st.platform ?? 'the other platform'}? This can't be undone.`)) return;
    void run(() => releaseFixedBlockNow(eventId), 'Released. The count is below and in your email.');
  };

  return (
    <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-4">
      <div className="flex items-center space-x-3">
        <Boxes className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Selling a block for another platform</h2>
      </div>
      <p className="type text-xs text-white/50">
        Selling mainly on DICE, Shotgun, RA or your own box office? Lower the capacity there by the block, and Exos sells
        that block on its page, your tracking links and discovery (and on marketplaces if the event qualifies for resale).
        At the release time Exos stops and tells you how many of each ticket type to put back on sale there. Exos can't
        change your listing on that platform.
      </p>

      {st.on && <p role="status" className="type text-xs text-white/80">{blockLine(st)}</p>}

      {st.release && (
        <div className="space-y-2">
          <p className="type text-xs text-amber-400">
            Released {when(st.release.releasedAt)} ({st.release.reason === 'manual' ? 'by hand' : 'on schedule'}). Put these back
            on sale on {st.release.platform}:
          </p>
          <table className="type text-xs text-white/80">
            <tbody>
              {st.tiers.map((t) => (
                <tr key={t.tierId}>
                  <td className="pr-4 py-0.5">{t.name}</td>
                  <td className="pr-4 py-0.5 font-bold">{blockUnits(t.returned ?? 0, t)}</td>
                  <td className="pr-4 py-0.5 text-white/50">sold {t.sold} of {t.block} on Exos</td>
                  {(t.moreToReturn ?? 0) > 0 && <td className="py-0.5 text-amber-400">+{t.moreToReturn} more came back since</td>}
                </tr>
              ))}
            </tbody>
          </table>
          {st.release.totalPending > 0 && (
            <p className="type text-[11px] text-white/50">
              {st.release.totalPending} were in a checkout or on a marketplace at the release; any that don't sell show up as "came back since".
            </p>
          )}
          <p className="type text-[11px] text-white/50">
            Exos tickets are on your door list. Import {st.release.platform}'s attendee export into a guest list for the rest.
          </p>
        </div>
      )}

      {!st.on && !st.release && st.canManage && !editing && st.primarySource === 'exos' && !st.cancelled && (
        <button type="button" className={BTN} onClick={() => setEditing(true)}>Sell a block</button>
      )}
      {!st.on && st.primarySource !== 'exos' && st.primarySource !== 'external' && (
        <p className="type text-xs text-white/50">This event's primary syncs with Exos, so it needs no block.</p>
      )}

      {formOpen && (
        <div className="space-y-4">
          <div className="flex flex-wrap gap-3">
            <label className="block">
              <span className={LBL}>Platform</span>
              <input className={`${FLD} w-48`} list="exos-block-platforms" value={platform} maxLength={60}
                onChange={(e) => setPlatform(e.target.value)} placeholder="DICE" />
              <datalist id="exos-block-platforms">
                {BLOCK_PLATFORMS.map((p) => <option key={p} value={p} />)}
              </datalist>
            </label>
            <label className="block flex-1 min-w-[12rem]">
              <span className={LBL}>Its event page (optional)</span>
              <input className={`${FLD} w-full`} value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://" />
            </label>
          </div>
          {st.tiers.length === 0 ? (
            <p className="type text-xs text-amber-400">Add a ticket type and save the event first.</p>
          ) : (
            <div className="space-y-2">
              <span className={LBL}>Block per ticket type</span>
              {parsed.map(({ t, n }) => (
                <label key={t.tierId} className="flex items-center gap-3">
                  <span className="type text-xs text-white/80 w-40 truncate">{t.name}</span>
                  <input className={`${FLD} w-24`} inputMode="numeric" value={blocks[t.tierId] ?? ''} aria-invalid={n === undefined}
                    onChange={(e) => setBlocks({ ...blocks, [t.tierId]: e.target.value })} />
                  <span className="type text-[11px] text-white/50">
                    {t.table ? `tables${t.partySize ? ` of ${t.partySize}` : ''}` : 'tickets'}{t.sold > 0 ? `, ${t.sold} sold` : ''}
                  </span>
                </label>
              ))}
            </div>
          )}
          <label className="block">
            <span className={LBL}>Hand back unsold at</span>
            <input type="datetime-local" className={FLD} value={release} onChange={(e) => setRelease(e.target.value)} />
            <span className="type block text-[11px] text-white/50 mt-1">
              {release === ''
                ? `Empty: 24 hours before doors${st.releaseAtDefault ? ` (${when(st.releaseAtDefault)})` : ''}.`
                : 'Clear it to use 24 hours before doors.'}
            </span>
          </label>
          <div className="flex flex-wrap gap-3">
            <button type="button" className={BTN} disabled={busy || !valid} onClick={save}>{st.on ? 'Save block' : 'Start selling the block'}</button>
            {st.on && (
              <button type="button" className={BTN} disabled={busy} onClick={releaseNow}>Release now</button>
            )}
            {st.on && (
              <button type="button" className={BTN} disabled={busy} onClick={() => void run(() => setFixedBlock(eventId, null), 'Block turned off: Exos is the primary again.')}>
                Turn off
              </button>
            )}
            {!st.on && (
              <button type="button" className={BTN} disabled={busy} onClick={() => show(st)}>Cancel</button>
            )}
          </div>
          {!valid && (
            <p role="alert" className="type text-[11px] text-rose-400">
              Name the platform; give every ticket type a block of 1 to 100000 (not below what it sold); a link must start with https://.
            </p>
          )}
          {st.on && st.releaseAt && (
            <p className="type text-[11px] text-white/50">Exos hands the unsold block back {when(st.releaseAt)}.</p>
          )}
        </div>
      )}
    </section>
  );
}
