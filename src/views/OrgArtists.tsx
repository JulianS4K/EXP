// /orgs/:orgId/artists — the organization's artists (mig 20261030110000):
// create and edit (name, permalink, Spotify link, photo, genres, bio, links),
// and merge duplicates (owner / manager). Lineups are edited on each event.

import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import {
  ARTIST_LINK_KEYS, artistDraftError, listOrgArtists, mergeArtist, saveArtist, searchArtists, uploadArtistImage,
  type Artist, type ArtistDraft,
} from '../lib/artists';

const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2';
const FLD = 'w-full bg-white border border-slate-200 rounded-lg px-4 py-3 text-sm text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-tm-blue disabled:opacity-60 disabled:bg-slate-50';
const CARD = 'bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8';
const BTN = 'px-4 py-2 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 hover:border-tm-blue hover:text-tm-blue transition-colors disabled:opacity-40';

const LINK_LABELS: Record<string, string> = {
  website: 'Website', instagram: 'Instagram', facebook: 'Facebook', twitter: 'X / Twitter', tiktok: 'TikTok',
  youtube: 'YouTube', soundcloud: 'SoundCloud', bandcamp: 'Bandcamp', apple_music: 'Apple Music',
};

interface Form {
  name: string;
  permalink: string;
  spotify: string;
  genres: string;
  bio: string;
  links: Record<string, string>;
  image_url: string | null;
}

const blank = (): Form => ({ name: '', permalink: '', spotify: '', genres: '', bio: '', links: {}, image_url: null });
const formOf = (a: Artist): Form => ({
  name: a.name, permalink: a.permalink, spotify: a.spotify_url ?? '', genres: a.genres.join(', '), bio: a.bio ?? '',
  links: { ...a.links }, image_url: a.image_url,
});

export default function OrgArtists() {
  const { orgId } = useParams<{ orgId: string }>();
  const { user, isAdmin } = useAuth();
  const { activeRole } = useOrganization();
  const { toast } = useToast();
  const navigate = useNavigate();
  const canEdit = isAdmin || ['owner', 'manager', 'content'].includes(activeRole ?? '');
  const canMerge = isAdmin || ['owner', 'manager'].includes(activeRole ?? '');

  const [artists, setArtists] = useState<Artist[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [query, setQuery] = useState('');
  const [showMerged, setShowMerged] = useState(false);
  const [editing, setEditing] = useState<Artist | 'new' | null>(null);
  const [form, setForm] = useState<Form>(blank());
  const [mergeInto, setMergeInto] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!orgId) return undefined;
    let alive = true;
    listOrgArtists(orgId, { includeMerged: true })
      .then((l) => alive && setArtists(l))
      .catch(() => alive && setFailed(true));
    return () => { alive = false; };
  }, [orgId]);

  const visible = useMemo(() => {
    const list = (artists ?? []).filter((a) => showMerged || !a.canonical_artist_id);
    return query.trim() ? searchArtists(list, query, 200) : list;
  }, [artists, query, showMerged]);
  const byId = useMemo(() => new Map((artists ?? []).map((a) => [a.id, a])), [artists]);

  if (!user) return <div className="min-h-screen bg-tm-gray p-24 text-center text-slate-500 font-bold uppercase tracking-widest">Sign in required.</div>;
  if (!orgId) return null;

  const open = (a: Artist | 'new') => {
    setEditing(a);
    setForm(a === 'new' ? blank() : formOf(a));
    setMergeInto('');
  };

  const upsert = (a: Artist) => setArtists((l) => [...(l ?? []).filter((x) => x.id !== a.id), a].sort((x, y) => x.name.localeCompare(y.name)));

  const save = async () => {
    const draft: ArtistDraft = {
      name: form.name.trim(),
      spotify: form.spotify.trim(),
      bio: form.bio.trim(),
      genres: form.genres.split(',').map((g) => g.trim()).filter(Boolean),
      links: Object.fromEntries(Object.entries(form.links).map(([k, v]) => [k, String(v).trim()] as const).filter(([, v]) => v)),
      image_url: form.image_url,
      ...(form.permalink.trim() ? { permalink: form.permalink.trim() } : {}),
    };
    const problem = artistDraftError(draft);
    if (problem) { toast({ kind: 'error', message: problem }); return; }
    setBusy(true);
    try {
      const a = await saveArtist(orgId, editing === 'new' ? null : editing!.id, draft);
      upsert(a);
      setEditing(a);
      setForm(formOf(a));
      toast({ kind: 'success', message: `${a.name} saved.` });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const upload = async (file: File | undefined) => {
    if (!file) return;
    setBusy(true);
    try {
      setForm((f) => ({ ...f, image_url: null }));
      const url = await uploadArtistImage(user.uid, file);
      setForm((f) => ({ ...f, image_url: url }));
      toast({ kind: 'success', message: 'Photo uploaded. Save to keep it.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const merge = async () => {
    if (editing === 'new' || !editing || !mergeInto) return;
    const target = byId.get(mergeInto);
    if (!window.confirm(`Merge ${editing.name} into ${target?.name}? Its lineup spots move to ${target?.name}; this can't be undone here.`)) return;
    setBusy(true);
    try {
      const r = await mergeArtist(editing.id, mergeInto);
      upsert(r.artist);
      setEditing(null);
      toast({ kind: 'success', message: `Merged. ${r.eventsUpdated} event lineup${r.eventsUpdated === 1 ? '' : 's'} updated.` });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const current = editing && editing !== 'new' ? editing : null;
  const targets = (artists ?? []).filter((a) => !a.canonical_artist_id && a.id !== current?.id);

  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-5xl mx-auto px-4 py-10">
        <button onClick={() => navigate(`/orgs/${orgId}/settings`)} className="flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-slate-400 hover:text-slate-700 mb-6">
          <ArrowLeft className="w-4 h-4" aria-hidden="true" /> Org settings
        </button>
        <h1 className="text-2xl font-black uppercase tracking-tight mb-1">Artists</h1>
        <p className="text-sm text-slate-500 mb-6">
          The acts on your lineups. Each lineup shows on the event page and its search listing, your website widget and
          the listing feed. Duplicates can be merged.
        </p>

        {failed && <div role="alert" className="bg-amber-50 border border-amber-200 rounded-lg p-4 text-amber-700 text-sm">Artists aren't available on this Exos install yet.</div>}

        {artists && (
          <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
            <div className={`${CARD} lg:col-span-2`}>
              <div className="flex gap-2 mb-3">
                <input aria-label="Search artists" className={FLD} placeholder="Search" value={query} onChange={(e) => setQuery(e.target.value)} />
                {canEdit && <button type="button" className={BTN} onClick={() => open('new')}>New</button>}
              </div>
              <label className="flex items-center gap-2 text-xs text-slate-500 mb-3">
                <input type="checkbox" checked={showMerged} onChange={(e) => setShowMerged(e.target.checked)} /> Show merged
              </label>
              {visible.length === 0 && <p className="text-sm text-slate-400">No artists yet. Add one here or from an event's lineup.</p>}
              <ul data-testid="org-artists" className="divide-y divide-slate-100">
                {visible.map((a) => (
                  <li key={a.id}>
                    <button type="button" onClick={() => open(a)}
                      className={`w-full flex items-center gap-3 py-2 text-left ${current?.id === a.id ? 'text-tm-blue' : ''}`}>
                      {a.image_thumb_url ? <img src={a.image_thumb_url} alt="" className="w-8 h-8 rounded object-cover" /> : <span className="w-8 h-8 rounded bg-slate-100" aria-hidden="true" />}
                      <span className="flex-1 min-w-0">
                        <span className="block text-sm font-bold truncate">{a.name}</span>
                        <span className="block text-[11px] text-slate-400 truncate">
                          /{a.permalink}{a.canonical_artist_id ? ` · merged into ${byId.get(a.canonical_artist_id)?.name ?? 'another artist'}` : ''}
                        </span>
                      </span>
                      {a.spotify_id && <span className="text-[10px] font-black uppercase text-emerald-600">Spotify</span>}
                    </button>
                  </li>
                ))}
              </ul>
            </div>

            {editing && (
              <div className={`${CARD} lg:col-span-3 space-y-4`}>
                <h2 className="text-sm font-black uppercase tracking-widest">{editing === 'new' ? 'New artist' : editing.name}</h2>
                <div>
                  <label htmlFor="artist-name" className={LBL}>Name</label>
                  <input id="artist-name" className={FLD} disabled={!canEdit} value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
                </div>
                <div className="grid sm:grid-cols-2 gap-4">
                  <div>
                    <label htmlFor="artist-permalink" className={LBL}>Permalink</label>
                    <input id="artist-permalink" className={FLD} disabled={!canEdit} value={form.permalink} placeholder="made from the name"
                      onChange={(e) => setForm({ ...form, permalink: e.target.value.toLowerCase() })} />
                  </div>
                  <div>
                    <label htmlFor="artist-spotify" className={LBL}>Spotify link</label>
                    <input id="artist-spotify" className={FLD} disabled={!canEdit} value={form.spotify} placeholder="https://open.spotify.com/artist/…"
                      onChange={(e) => setForm({ ...form, spotify: e.target.value })} />
                  </div>
                </div>
                <div>
                  <span className={LBL}>Photo</span>
                  <div className="flex items-center gap-3">
                    {form.image_url ? <img src={form.image_url} alt="" className="w-16 h-16 rounded object-cover" /> : <span className="w-16 h-16 rounded bg-slate-100" aria-hidden="true" />}
                    {canEdit && (
                      <>
                        <input aria-label="Upload a photo" type="file" accept="image/png,image/jpeg,image/webp" disabled={busy}
                          onChange={(e) => upload(e.target.files?.[0])} className="text-xs" />
                        {form.image_url && <button type="button" className={BTN} onClick={() => setForm({ ...form, image_url: null })}>Remove</button>}
                      </>
                    )}
                  </div>
                </div>
                <div>
                  <label htmlFor="artist-genres" className={LBL}>Genres (comma-separated, up to 10)</label>
                  <input id="artist-genres" className={FLD} disabled={!canEdit} value={form.genres} onChange={(e) => setForm({ ...form, genres: e.target.value })} />
                </div>
                <div>
                  <label htmlFor="artist-bio" className={LBL}>Bio</label>
                  <textarea id="artist-bio" rows={3} className={FLD} disabled={!canEdit} value={form.bio} onChange={(e) => setForm({ ...form, bio: e.target.value })} />
                </div>
                <div className="grid sm:grid-cols-2 gap-4">
                  {ARTIST_LINK_KEYS.map((k) => (
                    <div key={k}>
                      <label htmlFor={`artist-link-${k}`} className={LBL}>{LINK_LABELS[k]}</label>
                      <input id={`artist-link-${k}`} className={FLD} disabled={!canEdit} value={form.links[k] ?? ''} placeholder="https://"
                        onChange={(e) => setForm({ ...form, links: { ...form.links, [k]: e.target.value } })} />
                    </div>
                  ))}
                </div>
                {canEdit && (
                  <div className="flex gap-2">
                    <button type="button" className={BTN} disabled={busy} onClick={save}>Save</button>
                    <button type="button" className={BTN} disabled={busy} onClick={() => setEditing(null)}>Close</button>
                  </div>
                )}
                {current && canMerge && !current.canonical_artist_id && targets.length > 0 && (
                  <div className="border-t border-slate-100 pt-4">
                    <label htmlFor="artist-merge" className={LBL}>Merge into another artist (same act entered twice)</label>
                    <div className="flex gap-2">
                      <select id="artist-merge" className={FLD} value={mergeInto} onChange={(e) => setMergeInto(e.target.value)}>
                        <option value="">Choose the artist to keep…</option>
                        {targets.map((a) => <option key={a.id} value={a.id}>{a.name} (/{a.permalink})</option>)}
                      </select>
                      <button type="button" className={BTN} disabled={busy || !mergeInto} onClick={merge}>Merge</button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
