// Org → Series and collections (/orgs/:orgId/collections). The org's series
// (linking to each one's dates) and its collections: public pages at
// /c/<org slug>/<slug> grouping events by hand (up to 100) or by a rule
// (a series, an artist, a venue or a tag), resolved on every read against
// the org's upcoming published events. Owners, managers and content staff
// edit collections (RLS); mig 20261030150000.

import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Layers } from 'lucide-react';
import {
  deleteCollection, listCollections, listOrgSeries, saveCollection, type CollectionRow, type CollectionRuleKind, type SeriesRow,
} from '../lib/seriesTimedApi';
import { listOrgEvents } from '../lib/events';
import { slugify } from '../lib/slots';
import { supabase } from '../lib/supabase';
import { useToast } from '../context/ToastContext';
import type { Event } from '../types';

const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1';
const INPUT = 'px-2 py-1.5 border border-slate-200 rounded text-sm bg-white';
const BTN = 'px-3 py-1.5 border border-slate-200 rounded-lg text-[10px] font-black uppercase tracking-widest disabled:opacity-40';

type Draft = Omit<CollectionRow, 'id'> & { id?: string };

export default function OrgCollections() {
  const { orgId } = useParams<{ orgId: string }>();
  const { toast } = useToast();
  const [orgSlug, setOrgSlug] = useState('');
  const [series, setSeries] = useState<SeriesRow[]>([]);
  const [rows, setRows] = useState<CollectionRow[]>([]);
  const [events, setEvents] = useState<Event[]>([]);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    if (!orgId) return;
    try {
      const [s, c, e, o] = await Promise.all([
        listOrgSeries(orgId), listCollections(orgId), listOrgEvents(orgId),
        supabase.from('exos_orgs').select('slug').eq('id', orgId).maybeSingle(),
      ]);
      setSeries(s);
      setRows(c);
      setEvents(e);
      setOrgSlug(String((o.data as { slug?: string } | null)?.slug ?? ''));
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not load series and collections.' });
    }
  }, [orgId, toast]);
  useEffect(() => { void load(); }, [load]);

  const blank = (): Draft => ({
    orgId: orgId!, name: '', slug: '', description: null, imageUrl: null, mode: 'manual', eventIds: [],
    ruleKind: null, ruleValue: null, published: false,
  });

  const save = async () => {
    if (!draft) return;
    setBusy(true);
    try {
      await saveCollection({ ...draft, slug: draft.slug || slugify(draft.name) });
      setDraft(null);
      await load();
      toast({ kind: 'success', message: 'Collection saved.' });
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not save the collection.' });
    } finally { setBusy(false); }
  };

  return (
    <div className="bg-[#f2f4f7] min-h-screen">
      <div className="max-w-5xl mx-auto px-4 py-12">
        <Link to={`/orgs/${orgId}/settings`} className="flex items-center gap-2 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6">
          <ArrowLeft size={14} /> Org settings
        </Link>
        <h1 className="text-3xl font-bold tracking-tight text-slate-900 mb-6">Series and collections</h1>

        <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
          <h3 className="text-sm font-bold text-slate-700 mb-2">Series</h3>
          {series.length === 0 && <p className="text-xs text-slate-400">No series yet. Open an event's report and choose “Make it recurring”.</p>}
          <ul className="text-sm space-y-1">
            {series.map((s) => (
              <li key={s.id}><Link className="text-[#026cdf] font-bold" to={`/dashboard/series/${s.id}`}>{s.name}</Link>
                <span className="text-xs text-slate-400"> · {s.status}</span></li>
            ))}
          </ul>
        </div>

        <div className="bg-white rounded-2xl p-6 shadow-sm">
          <div className="flex items-center justify-between mb-2">
            <h3 className="text-sm font-bold text-slate-700 flex items-center gap-2"><Layers className="w-4 h-4" /> Collections</h3>
            <button type="button" className={BTN} onClick={() => setDraft(blank())}>New collection</button>
          </div>
          <ul className="text-sm divide-y divide-slate-100">
            {rows.map((c) => (
              <li key={c.id} className="py-2 flex items-center justify-between gap-2">
                <span>
                  <span className="font-bold">{c.name}</span>
                  <span className="text-xs text-slate-400"> · {c.mode === 'manual' ? `${c.eventIds.length} event(s)` : `${c.ruleKind}: ${c.ruleValue}`} · {c.published ? 'published' : 'draft'}</span>
                </span>
                <span className="flex gap-3 text-xs">
                  {c.published && orgSlug && <Link className="text-[#026cdf]" to={`/c/${orgSlug}/${c.slug}`}>View</Link>}
                  <button type="button" className="text-[#026cdf]" onClick={() => setDraft({ ...c })}>Edit</button>
                  <button type="button" className="text-red-600" onClick={async () => {
                    if (!window.confirm(`Delete "${c.name}"?`)) return;
                    try { await deleteCollection(c.id); await load(); } catch (err: any) { toast({ kind: 'error', message: err?.message || 'Could not delete.' }); }
                  }}>Delete</button>
                </span>
              </li>
            ))}
          </ul>

          {draft && (
            <div className="mt-4 border-t border-slate-100 pt-4 space-y-3">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <label><span className={LBL}>Name</span>
                  <input className={`${INPUT} w-full`} value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value, slug: draft.id ? draft.slug : slugify(e.target.value) })} /></label>
                <label><span className={LBL}>Link /c/{orgSlug || 'org'}/…</span>
                  <input className={`${INPUT} w-full`} value={draft.slug} onChange={(e) => setDraft({ ...draft, slug: slugify(e.target.value) })} /></label>
                <label className="sm:col-span-2"><span className={LBL}>Description</span>
                  <textarea rows={2} className={`${INPUT} w-full`} value={draft.description ?? ''} onChange={(e) => setDraft({ ...draft, description: e.target.value })} /></label>
                <label className="sm:col-span-2"><span className={LBL}>Image URL</span>
                  <input className={`${INPUT} w-full`} value={draft.imageUrl ?? ''} onChange={(e) => setDraft({ ...draft, imageUrl: e.target.value })} /></label>
              </div>
              <div className="flex flex-wrap gap-3 items-end">
                <label><span className={LBL}>Events</span>
                  <select className={INPUT} value={draft.mode} onChange={(e) => setDraft({ ...draft, mode: e.target.value as 'manual' | 'rule' })}>
                    <option value="manual">Picked by hand</option><option value="rule">Matching a rule</option>
                  </select></label>
                {draft.mode === 'rule' && (<>
                  <label><span className={LBL}>Rule</span>
                    <select className={INPUT} value={draft.ruleKind ?? 'venue'} onChange={(e) => setDraft({ ...draft, ruleKind: e.target.value as CollectionRuleKind, ruleValue: '' })}>
                      <option value="series">A series</option><option value="artist">An artist</option>
                      <option value="venue">A venue</option><option value="tag">A tag / genre</option>
                    </select></label>
                  {(draft.ruleKind ?? 'venue') === 'series' ? (
                    <select aria-label="Series" className={INPUT} value={draft.ruleValue ?? ''} onChange={(e) => setDraft({ ...draft, ruleKind: 'series', ruleValue: e.target.value })}>
                      <option value="">Pick a series</option>
                      {series.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                    </select>
                  ) : (
                    <input aria-label="Rule value" className={INPUT} placeholder="e.g. Blue Room" value={draft.ruleValue ?? ''}
                      onChange={(e) => setDraft({ ...draft, ruleKind: draft.ruleKind ?? 'venue', ruleValue: e.target.value })} />
                  )}
                </>)}
                <label className="text-sm flex items-center gap-1.5">
                  <input type="checkbox" checked={draft.published} onChange={(e) => setDraft({ ...draft, published: e.target.checked })} /> Published
                </label>
              </div>
              {draft.mode === 'manual' && (
                <div className="max-h-56 overflow-auto border border-slate-100 rounded p-2 text-sm">
                  {events.map((e) => (
                    <label key={e.id} className="flex items-center gap-2">
                      <input type="checkbox" checked={draft.eventIds.includes(e.id)}
                        onChange={(x) => setDraft({ ...draft, eventIds: x.target.checked ? [...draft.eventIds, e.id].slice(0, 100) : draft.eventIds.filter((i) => i !== e.id) })} />
                      {e.title} <span className="text-xs text-slate-400">{e.date?.toDate?.().toISOString().slice(0, 10)} · {e.status}</span>
                    </label>
                  ))}
                </div>
              )}
              <p className="text-[11px] text-slate-400">The public page lists only upcoming published events, soonest first.</p>
              <div className="flex gap-2">
                <button type="button" disabled={busy || !draft.name.trim() || (draft.mode === 'rule' && !draft.ruleValue)} className={BTN} onClick={save}>Save</button>
                <button type="button" className={BTN} onClick={() => setDraft(null)}>Cancel</button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
