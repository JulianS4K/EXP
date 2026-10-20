// Edit event → Also sell on (mig 20261019090000): the event mirrored 1-1 on
// Eventbrite (and Luma once switched on), and the primary ticketing system
// whose QR codes the event is shared on other markets with. Exos is the
// source: edits here go there on the next sync; sales everywhere share one count.

import { useCallback, useEffect, useState } from 'react';
import { Share2 } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useToast } from '../context/ToastContext';
import {
  CHANNEL_LABEL, CHANNELS, externalIdFrom, fetchChannelStatus, mirrorLine, pushChannels, removeChannel, setChannel,
  setLumaWrites, setPrimary, type Channel, type ChannelStatus, type PrimarySource,
} from '../lib/channels';

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const FLD = 'w-full bg-black border border-white/20 px-3 py-2 text-xs text-white';

export default function ChannelsPanel({ eventId, orgId }: { eventId: string; orgId?: string }) {
  const { toast } = useToast();
  const [st, setSt] = useState<ChannelStatus | null>(null);
  const [hidden, setHidden] = useState(false);
  const [busy, setBusy] = useState(false);
  const [linkInput, setLinkInput] = useState<Record<Channel, string>>({ eventbrite: '', luma: '' });

  const load = useCallback(() => {
    fetchChannelStatus(eventId).then(setSt).catch(() => setHidden(true));
  }, [eventId]);
  useEffect(load, [load]);
  if (hidden || !st) return null;

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast({ kind: 'success', message: ok });
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  const mirrorOf = (p: Channel) => st.mirrors.find((m) => m.provider === p) ?? null;
  const primaries: PrimarySource[] = ['exos', ...CHANNELS.filter((p) => mirrorOf(p))];
  if (st.primary !== 'exos' && !primaries.includes(st.primary)) primaries.push(st.primary);

  return (
    <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-5">
      <div className="flex items-center space-x-3">
        <Share2 className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Also sell on</h2>
      </div>
      <p className="type text-xs text-white/50">
        Exos creates the event there and keeps its details, ticket types and prices in step with this page. Sales on
        every platform come off one count, and the platforms split what is left, less one order's worth each held back
        for the minutes between syncs. Edit here, not there: an edit made on the other
        platform is replaced by the next change in Exos.
      </p>

      {CHANNELS.map((p) => {
        const m = mirrorOf(p);
        const connected = st.connected[p];
        return (
          <div key={p} className="border-t border-white/10 pt-4 space-y-2">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="type text-[11px] uppercase tracking-widest text-white/70">{CHANNEL_LABEL[p]}</p>
              {m?.externalUrl && (
                <a href={m.externalUrl} target="_blank" rel="noopener noreferrer" className="type text-[11px] underline text-white/60">
                  Open on {CHANNEL_LABEL[p]}
                </a>
              )}
            </div>
            {!connected ? (
              <p className="type text-xs text-white/50">
                Connect {CHANNEL_LABEL[p]} first: {p === 'eventbrite'
                  ? <Link to="/door" className="underline">the door app → Eventbrite</Link>
                  : orgId ? <Link to={`/orgs/${orgId}/settings`} className="underline">Org settings → Integrations</Link> : 'Org settings → Integrations'}.
              </p>
            ) : m ? (
              <>
                <p className={`type text-xs ${m.status === 'error' ? 'text-rose-400' : 'text-white/70'}`}>{mirrorLine(m, st.writes[p])}</p>
                {st.canManage && (
                  <div className="flex flex-wrap gap-2">
                    <button type="button" className={BTN} disabled={busy} onClick={() => void run(() => pushChannels(eventId), 'Syncing now.')}>Sync now</button>
                    {st.primary !== p && (
                      <button type="button" className={BTN} disabled={busy}
                        onClick={() => void run(() => removeChannel(eventId, p), `Stopped syncing to ${CHANNEL_LABEL[p]}. The event there is left as it is.`)}>
                        Stop syncing
                      </button>
                    )}
                  </div>
                )}
              </>
            ) : st.canManage ? (
              <div className="space-y-2">
                <div className="flex flex-wrap gap-2">
                  <button type="button" className={BTN} disabled={busy}
                    onClick={() => void run(() => setChannel(eventId, p), `Creating it on ${CHANNEL_LABEL[p]} on the next sync.`)}>
                    Create it on {CHANNEL_LABEL[p]}
                  </button>
                </div>
                <label className="block">
                  <span className="type block text-[10px] uppercase tracking-widest text-white/50 mb-1">Or link an event that's already there</span>
                  <div className="flex gap-2">
                    <input className={FLD} value={linkInput[p]} onChange={(e) => setLinkInput({ ...linkInput, [p]: e.target.value })}
                      placeholder={p === 'eventbrite' ? 'https://www.eventbrite.com/e/…-123456789' : 'https://luma.com/event/manage/evt-…'} />
                    <button type="button" className={BTN} disabled={busy || !linkInput[p].trim()}
                      onClick={() => {
                        const id = externalIdFrom(p, linkInput[p]);
                        if (!id) { toast({ kind: 'error', message: `That doesn't look like a ${CHANNEL_LABEL[p]} event link.` }); return; }
                        void run(() => setChannel(eventId, p, id), `Linked. Exos takes it over on the next sync.`);
                      }}>Link</button>
                  </div>
                </label>
              </div>
            ) : (
              <p className="type text-xs text-white/40">Not sold there.</p>
            )}
            {connected && !st.writes[p] && (
              <p className="type text-[11px] text-white/40">
                {p === 'eventbrite'
                  ? 'Sending to Eventbrite is off: the org owner switches it on in the door app (and the operator’s server setting must allow it). Until then Exos only records what it would send.'
                  : st.canSwitch
                    ? <>Sending to Luma is off. <button type="button" className="underline" disabled={busy}
                        onClick={() => orgId && void run(() => setLumaWrites(orgId, true), 'Sending to Luma is on for this org.')}>Switch it on</button> (the operator&rsquo;s server setting must allow it too).</>
                    : 'Sending to Luma is off: the org owner switches it on.'}
              </p>
            )}
          </div>
        );
      })}

      <div className="border-t border-white/10 pt-4 space-y-2">
        <p className="type text-[11px] uppercase tracking-widest text-white/70">Primary ticketing system</p>
        <p className="type text-xs text-white/50">
          Whose QR codes the event is shared on other markets with (the last listing set is sold there), and where comps go.
        </p>
        <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Primary ticketing system">
          {primaries.map((p) => (
            <button key={p} type="button" role="radio" aria-checked={st.primary === p} disabled={!st.canManage || busy || st.primary === p}
              onClick={() => void run(() => setPrimary(eventId, p), `${CHANNEL_LABEL[p]} is the primary ticketing system.`)}
              className={`${BTN} ${st.primary === p ? 'border-brand-primary text-brand-primary' : ''}`}>
              {CHANNEL_LABEL[p]}
            </button>
          ))}
        </div>
        {st.primary === 'eventbrite' && (
          <p className="type text-[11px] text-white/40">Eventbrite can't add guests through its API, so comps for this event are Exos tickets.</p>
        )}
        {st.compsQueued > 0 && <p className="type text-[11px] text-white/50">{st.compsQueued} comp guests waiting to be added on Luma.</p>}
      </div>
    </section>
  );
}
