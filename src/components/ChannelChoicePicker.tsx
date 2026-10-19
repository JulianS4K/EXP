// Create event → Ticketing (mig 20261019090000): the primary ticketing system
// (whose QR codes the event is shared on other markets with) and the other
// platforms Exos should also sell it on, created there after the event saves.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { CHANNEL_LABEL, CHANNELS, fetchConnections, normalizeChoice, type Channel, type ChannelChoice, type Connections, type PrimarySource } from '../lib/channels';

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';

export default function ChannelChoicePicker({ orgId, value, onChange }: {
  orgId?: string; value: ChannelChoice; onChange: (v: ChannelChoice) => void;
}) {
  const [conn, setConn] = useState<Connections | null>(null);
  useEffect(() => {
    if (!orgId) return;
    fetchConnections(orgId).then(setConn).catch(() => setConn(null));
  }, [orgId]);
  if (!orgId) return null;

  const usable = (p: Channel) => conn?.[p] === true;
  const set = (v: ChannelChoice) => onChange(normalizeChoice(v));
  const primaries: PrimarySource[] = ['exos', ...CHANNELS];

  return (
    <div className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-5">
      <div>
        <h3 className="disp text-lg uppercase tracking-wide text-white">Ticketing</h3>
        <p className="type text-xs text-white/50 mt-1">
          Sell on Exos, and on other platforms too. Exos creates the event there with the same details, ticket types and
          prices, keeps them in step, and shares one count so nothing oversells.
        </p>
      </div>

      <div className="space-y-2">
        <p className="type text-[10px] uppercase tracking-widest text-white/50">Primary ticketing system (QR codes)</p>
        <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Primary ticketing system">
          {primaries.map((p) => (
            <button key={p} type="button" role="radio" aria-checked={value.primary === p}
              disabled={p !== 'exos' && !usable(p)}
              onClick={() => set({ ...value, primary: p })}
              className={`${BTN} ${value.primary === p ? 'border-brand-primary text-brand-primary' : ''}`}>
              {CHANNEL_LABEL[p]}
            </button>
          ))}
        </div>
        <p className="type text-[11px] text-white/40">
          When the event is shared on other markets, tickets go out with this platform's QR codes.
        </p>
      </div>

      <div className="space-y-2">
        <p className="type text-[10px] uppercase tracking-widest text-white/50">Also sell on</p>
        {CHANNELS.map((p) => (
          <label key={p} className="flex items-center gap-2 type text-xs text-white/80">
            <input type="checkbox" disabled={!usable(p) || value.primary === p}
              checked={value.also.includes(p)}
              onChange={(e) => set({ ...value, also: e.target.checked ? [...value.also, p] : value.also.filter((x) => x !== p) })} />
            {CHANNEL_LABEL[p]}
            {conn && !usable(p) && (
              <span className="text-white/40">
                {' '}(connect it first: {p === 'eventbrite' ? <Link to="/door" className="underline">door app</Link> : <Link to={`/orgs/${orgId}/settings`} className="underline">Integrations</Link>})
              </span>
            )}
            {usable(p) && conn && !conn.writes[p] && <span className="text-white/40">(sending is off for now: Exos records what it would send)</span>}
          </label>
        ))}
      </div>
    </div>
  );
}
