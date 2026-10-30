// The structured lineup on the public event page (mig 20261030110000): photo,
// name, act type, set time and a Spotify link per act, in running order. The
// first act is drawn as the headliner. Renders nothing without a lineup.

import { ACT_TYPE_LABELS, orderedLineup, spotifyLinks, type LineupSlot } from '../lib/artists';
import { formatInTz } from '../lib/datetime';

export default function EventArtistLineup({ lineup, timezone }: { lineup: readonly LineupSlot[]; timezone?: string }) {
  const slots = orderedLineup(lineup);
  if (!slots.length) return null;
  return (
    <div data-testid="event-lineup" className="p-7 bg-[#111] sm:col-span-2">
      <p className="type text-[11px] text-white/60 uppercase tracking-widest mb-4">lineup</p>
      <ol className="space-y-3">
        {slots.map((s, i) => {
          const spotify = spotifyLinks(s.artist.spotify_id).spotify_url;
          const set = s.set_time ? formatInTz(new Date(s.set_time), timezone, { hour: 'numeric', minute: '2-digit' }) : null;
          return (
            <li key={s.id} data-testid="lineup-slot" className="flex items-center gap-4">
              {s.artist.image_thumb_url
                ? <img src={s.artist.image_thumb_url} alt="" loading="lazy" className={i === 0 ? 'w-14 h-14 object-cover' : 'w-10 h-10 object-cover'} />
                : <span aria-hidden="true" className={i === 0 ? 'w-14 h-14 bg-white/5' : 'w-10 h-10 bg-white/5'} />}
              <div className="min-w-0 flex-1">
                <p className={i === 0 ? 'disp text-3xl tracking-tight text-white' : 'disp text-xl tracking-tight text-white/70'}>
                  {s.artist.name}
                </p>
                <p className="type text-[10px] text-white/40 uppercase tracking-widest">
                  {ACT_TYPE_LABELS[s.act_type]}{set ? ` · ${set}` : ''}
                </p>
              </div>
              {spotify && (
                <a href={spotify} target="_blank" rel="noopener noreferrer" aria-label={`Listen to ${s.artist.name} on Spotify`}
                  className="type text-[10px] uppercase tracking-widest border border-white/20 px-3 py-2 text-white/70 hover:text-brand-primary hover:border-brand-primary">
                  Spotify
                </a>
              )}
            </li>
          );
        })}
      </ol>
    </div>
  );
}
