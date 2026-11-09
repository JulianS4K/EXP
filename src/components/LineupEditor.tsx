// The lineup editor on Edit Event (org events; mig 20261030110000). Search the
// org's artists or create one inline (name, Spotify link, photo), reorder with
// the arrows, pick act types. EditEvent saves it right after the event
// (`save()` on the handle); a lineup failure leaves the event saved and says so.

import { forwardRef, useEffect, useImperativeHandle, useMemo, useState } from 'react';
import { ArrowDown, ArrowUp, Plus, X } from 'lucide-react';
import {
  ACT_TYPES, ACT_TYPE_LABELS, addSlot, artistDraftError, draftFromLineup, getEventLineup, listOrgArtists, moveSlot,
  sameLineup, saveArtist, saveLineup, searchArtists, uploadArtistImage,
  type ActType, type Artist, type DraftSlot,
} from '../lib/artists';

export interface LineupEditorHandle {
  /** True when the lineup differs from what is saved. */
  dirty: () => boolean;
  /** Save it (throws with a readable message). */
  save: () => Promise<void>;
}

interface Props {
  eventId: string;
  orgId: string;
  uploaderUid?: string;
  /** Called whenever the lineup gains or loses its last act. */
  onHasLineup?: (has: boolean) => void;
}

const FIELD = 'w-full bg-black border border-white/20 py-3 px-4 text-white text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary';
const LABEL = 'type text-[11px] text-white/60 uppercase tracking-widest';
const BTN = 'type text-[10px] uppercase tracking-widest border border-white/20 px-3 py-2 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';

const LineupEditor = forwardRef<LineupEditorHandle, Props>(function LineupEditor({ eventId, orgId, uploaderUid, onHasLineup }, ref) {
  const [artists, setArtists] = useState<Artist[]>([]);
  const [slots, setSlots] = useState<DraftSlot[]>([]);
  const [saved, setSaved] = useState<DraftSlot[]>([]);
  const [loaded, setLoaded] = useState<'loading' | 'ok' | 'unavailable'>('loading');
  const [query, setQuery] = useState('');
  const [creating, setCreating] = useState<{ name: string; spotify: string; file: File | null } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    Promise.all([listOrgArtists(orgId), getEventLineup(eventId)])
      .then(([list, lineup]) => {
        if (!alive) return;
        const draft = draftFromLineup(lineup);
        setArtists(list);
        setSlots(draft);
        setSaved(draft);
        setLoaded('ok');
      })
      // Before the migration is on the database: no editor, the free-text performers stay.
      .catch(() => alive && setLoaded('unavailable'));
    return () => { alive = false; };
  }, [eventId, orgId]);

  useEffect(() => { onHasLineup?.(slots.length > 0); }, [slots.length, onHasLineup]);

  useImperativeHandle(ref, () => ({
    dirty: () => loaded === 'ok' && !sameLineup(slots, saved),
    save: async () => {
      const lineup = draftFromLineup(await saveLineup(eventId, slots));
      setSlots(lineup);
      setSaved(lineup);
    },
  }), [eventId, slots, saved, loaded]);

  const results = useMemo(() => searchArtists(artists, query), [artists, query]);
  const exact = artists.some((a) => a.name.toLowerCase() === query.trim().toLowerCase());

  if (loaded !== 'ok') return null;

  const add = (a: Artist) => {
    const next = addSlot(slots, a);
    if (typeof next === 'string') setError(next);
    else { setSlots(next); setError(null); setQuery(''); }
  };

  const create = async () => {
    if (!creating) return;
    const problem = artistDraftError({ name: creating.name, spotify: creating.spotify });
    if (problem) { setError(problem); return; }
    setBusy(true);
    setError(null);
    try {
      const image = creating.file && uploaderUid ? await uploadArtistImage(uploaderUid, creating.file) : null;
      const a = await saveArtist(orgId, null, {
        name: creating.name.trim(), spotify: creating.spotify.trim(), ...(image ? { image_url: image } : {}),
      });
      setArtists((list) => [...list, a].sort((x, y) => x.name.localeCompare(y.name)));
      setCreating(null);
      add(a);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const setSlot = (i: number, patch: Partial<DraftSlot>) => setSlots((s) => s.map((x, j) => (j === i ? { ...x, ...patch } : x)));

  return (
    <div data-testid="lineup-editor" className="space-y-4 md:col-span-2">
      <div>
        <p className={LABEL}>Lineup</p>
        <p className="type text-[10px] text-white/40 mt-1">
          Your artists, in running order. Shown on the event page, in the listing feed and on your website widget; the
          first 10 names become the event's performers. Manage artists in Org settings → Artists.
        </p>
      </div>

      {slots.length > 0 && (
        <ol className="border border-white/10 divide-y divide-white/10">
          {slots.map((s, i) => (
            <li key={s.artist.id} data-testid="lineup-editor-slot" className="flex flex-wrap items-center gap-3 p-3">
              <span className="type text-[10px] text-white/40 w-5">{i + 1}</span>
              {s.artist.image_thumb_url
                ? <img src={s.artist.image_thumb_url} alt="" className="w-8 h-8 object-cover" />
                : <span className="w-8 h-8 bg-white/10" aria-hidden="true" />}
              <span data-testid="lineup-editor-name" className="disp text-base text-white flex-1 min-w-[8rem]">{s.artist.name}</span>
              <label className="sr-only" htmlFor={`act-${s.artist.id}`}>Act type for {s.artist.name}</label>
              <select id={`act-${s.artist.id}`} value={s.actType} onChange={(e) => setSlot(i, { actType: e.target.value as ActType })}
                className="bg-black border border-white/20 text-white text-xs py-2 px-2">
                {ACT_TYPES.map((t) => <option key={t} value={t}>{ACT_TYPE_LABELS[t]}</option>)}
              </select>
              <button type="button" className={BTN} aria-label={`Move ${s.artist.name} up`} disabled={i === 0}
                onClick={() => setSlots((x) => moveSlot(x, i, -1))}><ArrowUp className="w-3 h-3" /></button>
              <button type="button" className={BTN} aria-label={`Move ${s.artist.name} down`} disabled={i === slots.length - 1}
                onClick={() => setSlots((x) => moveSlot(x, i, 1))}><ArrowDown className="w-3 h-3" /></button>
              <button type="button" className={BTN} aria-label={`Remove ${s.artist.name}`}
                onClick={() => setSlots((x) => x.filter((_, j) => j !== i))}><X className="w-3 h-3" /></button>
            </li>
          ))}
        </ol>
      )}

      {!creating && (
        <div className="space-y-2">
          <label htmlFor={`lineup-search-${eventId}`} className={LABEL}>Search your artists</label>
          <input id={`lineup-search-${eventId}`} className={FIELD} value={query} placeholder="Start typing a name"
            onChange={(e) => setQuery(e.target.value)} />
          {query.trim() && (
            <ul data-testid="lineup-search-results" className="border border-white/10">
              {results.map((a) => (
                <li key={a.id}>
                  <button type="button" onClick={() => add(a)} className="w-full text-left px-4 py-2 text-sm text-white hover:bg-white/5">
                    {a.name} <span className="text-white/40 text-xs">/{a.permalink}</span>
                  </button>
                </li>
              ))}
              {!exact && (
                <li>
                  <button type="button" onClick={() => setCreating({ name: query.trim(), spotify: '', file: null })}
                    className="w-full text-left px-4 py-2 text-sm text-brand-primary hover:bg-white/5 inline-flex items-center gap-2">
                    <Plus className="w-3 h-3" aria-hidden="true" /> Create “{query.trim()}”
                  </button>
                </li>
              )}
            </ul>
          )}
        </div>
      )}

      {creating && (
        <div className="border border-white/10 p-4 space-y-3">
          <div className="space-y-1">
            <label htmlFor={`new-artist-name-${eventId}`} className={LABEL}>Name</label>
            <input id={`new-artist-name-${eventId}`} className={FIELD} value={creating.name}
              onChange={(e) => setCreating({ ...creating, name: e.target.value })} />
          </div>
          <div className="space-y-1">
            <label htmlFor={`new-artist-spotify-${eventId}`} className={LABEL}>Spotify link (optional)</label>
            <input id={`new-artist-spotify-${eventId}`} className={FIELD} value={creating.spotify}
              placeholder="https://open.spotify.com/artist/…" onChange={(e) => setCreating({ ...creating, spotify: e.target.value })} />
          </div>
          {uploaderUid && (
            <div className="space-y-1">
              <label htmlFor={`new-artist-photo-${eventId}`} className={LABEL}>Photo (optional)</label>
              <input id={`new-artist-photo-${eventId}`} type="file" accept="image/png,image/jpeg,image/webp" className="text-xs text-white/60"
                onChange={(e) => setCreating({ ...creating, file: e.target.files?.[0] ?? null })} />
            </div>
          )}
          <div className="flex gap-2">
            <button type="button" className={BTN} disabled={busy} onClick={create}>Create and add</button>
            <button type="button" className={BTN} disabled={busy} onClick={() => { setCreating(null); setError(null); }}>Cancel</button>
          </div>
        </div>
      )}

      {error && <p role="alert" className="type text-xs text-red-400">{error}</p>}
    </div>
  );
});

export default LineupEditor;
