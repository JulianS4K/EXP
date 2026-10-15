// Org settings → Website (mig 20261016130000): the storefront's sections, a
// custom domain (tickets.yourvenue.com) and the widgets for any other site.

import { useCallback, useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, Copy, Globe, Plus, Trash2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  SECTION_TYPES, addDomain, listDomains, removeDomain, saveSite, siteError, starterSite, verifyDomain,
  type OrgDomain, type Site, type SiteItem, type SiteSection, type SectionType,
} from '../lib/site';
import { widgetSnippets } from '../lib/embedWidgets';
import { publicUrl } from '../lib/utils';

const LBL = 'block text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1';
const FLD = 'w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
const BTN = 'px-3 py-1.5 rounded text-[10px] font-black uppercase tracking-widest border border-slate-200 text-slate-700 disabled:opacity-50';

const ITEM_FIELDS: Partial<Record<SectionType, [string, string][]>> = {
  faq: [['q', 'Question'], ['a', 'Answer']],
  gallery: [['image', 'Image link (https)'], ['caption', 'Caption']],
  links: [['label', 'Button text'], ['url', 'Link (https)']],
};

function SectionEditor({ s, onChange }: { s: SiteSection; onChange: (s: SiteSection) => void }) {
  const set = (k: keyof SiteSection, v: string) => onChange({ ...s, [k]: v });
  const items = s.items ?? [];
  const fields = ITEM_FIELDS[s.type];
  return (
    <div className="space-y-2">
      {s.type !== 'gallery' && (
        <input className={FLD} value={s.title ?? ''} onChange={(e) => set('title', e.target.value)} placeholder="Heading" maxLength={200} />
      )}
      {s.type === 'hero' && (
        <>
          <input className={FLD} value={s.subtitle ?? ''} onChange={(e) => set('subtitle', e.target.value)} placeholder="Subtitle" maxLength={300} />
          <input className={FLD} value={s.image ?? ''} onChange={(e) => set('image', e.target.value)} placeholder="Banner image link (https://…)" />
          <div className="grid grid-cols-2 gap-2">
            <input className={FLD} value={s.button_label ?? ''} onChange={(e) => set('button_label', e.target.value)} placeholder="Button text" />
            <input className={FLD} value={s.button_url ?? ''} onChange={(e) => set('button_url', e.target.value)} placeholder="Button link (https://…)" />
          </div>
        </>
      )}
      {(s.type === 'about' || s.type === 'text' || s.type === 'newsletter') && (
        <textarea className={FLD} rows={4} value={s.body ?? ''} onChange={(e) => set('body', e.target.value)} maxLength={4000}
          placeholder={s.type === 'newsletter' ? 'One line on what fans get' : 'Text (markdown: **bold**, [links](https://…), - lists)'} />
      )}
      {fields && (
        <div className="space-y-2">
          {items.map((it, j) => (
            <div key={j} className="flex gap-2">
              {fields.map(([k, l]) => (
                <input key={k} className={FLD} value={it[k] ?? ''} placeholder={l}
                  onChange={(e) => onChange({ ...s, items: items.map((x, xi) => (xi === j ? { ...x, [k]: e.target.value } : x)) })} />
              ))}
              <button type="button" aria-label="Remove item" className={BTN} onClick={() => onChange({ ...s, items: items.filter((_, xi) => xi !== j) })}>
                <Trash2 className="w-3 h-3" aria-hidden="true" />
              </button>
            </div>
          ))}
          {items.length < 30 && (
            <button type="button" className={BTN} onClick={() => onChange({ ...s, items: [...items, {} as SiteItem] })}>Add</button>
          )}
        </div>
      )}
    </div>
  );
}

export default function WebsitePanel({ orgId, orgName, orgSlug, site: initial, canEdit }: {
  orgId: string; orgName: string; orgSlug: string; site: Site | null | undefined; canEdit: boolean;
}) {
  const { toast } = useToast();
  const [site, setSite] = useState<Site>(initial ?? starterSite(orgName));
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [domains, setDomains] = useState<OrgDomain[] | null>(null);
  const [newDomain, setNewDomain] = useState('');

  const loadDomains = useCallback(() => {
    if (!canEdit) return;
    listDomains(orgId).then(setDomains).catch(() => setDomains(null));
  }, [orgId, canEdit]);
  useEffect(loadDomains, [loadDomains]);

  const update = (next: Site) => { setSite(next); setDirty(true); };
  const err = siteError(site);
  const move = (i: number, d: -1 | 1) => {
    const s = [...site.sections];
    const j = i + d;
    if (j < 0 || j >= s.length) return;
    [s[i], s[j]] = [s[j], s[i]];
    update({ sections: s });
  };

  const save = async () => {
    setBusy(true);
    try {
      await saveSite(orgId, site);
      setDirty(false);
      toast({ kind: 'success', message: 'Website saved.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const copy = (text: string) => navigator.clipboard.writeText(text).then(
    () => toast({ kind: 'success', message: 'Copied.' }), () => toast({ kind: 'error', message: 'Copy failed.' }));

  const loader = publicUrl('embed.js');
  const host = (() => { try { return new URL(publicUrl('')).host; } catch { return ''; } })();

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-8">
      <div>
        <div className="flex items-center gap-2 mb-2">
          <Globe className="w-4 h-4 text-slate-500" aria-hidden="true" />
          <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest">Website</h2>
        </div>
        <p className="text-xs text-slate-400">
          Your page at <a className="underline" href={publicUrl(`o/${orgSlug}`)} target="_blank" rel="noreferrer">{publicUrl(`o/${orgSlug}`)}</a>.
          Pick the sections and their order; the event grid goes where "Upcoming events" is.
        </p>
      </div>

      <section className="space-y-3">
        {site.sections.map((s, i) => (
          <div key={i} className="border border-slate-200 rounded-xl p-4">
            <div className="flex items-center justify-between mb-2">
              <span className="text-[11px] font-black uppercase tracking-widest text-slate-600">
                {SECTION_TYPES.find((t) => t.type === s.type)?.label ?? s.type}
              </span>
              {canEdit && (
                <span className="flex gap-1">
                  <button type="button" aria-label="Move up" className={BTN} onClick={() => move(i, -1)}><ArrowUp className="w-3 h-3" aria-hidden="true" /></button>
                  <button type="button" aria-label="Move down" className={BTN} onClick={() => move(i, 1)}><ArrowDown className="w-3 h-3" aria-hidden="true" /></button>
                  <button type="button" aria-label="Remove section" className={BTN} onClick={() => update({ sections: site.sections.filter((_, x) => x !== i) })}><Trash2 className="w-3 h-3" aria-hidden="true" /></button>
                </span>
              )}
            </div>
            {s.type === 'events' ? (
              <input className={FLD} value={s.title ?? ''} disabled={!canEdit} placeholder="Upcoming"
                onChange={(e) => update({ sections: site.sections.map((x, xi) => (xi === i ? { ...x, title: e.target.value } : x)) })} />
            ) : (
              <SectionEditor s={s} onChange={(n) => update({ sections: site.sections.map((x, xi) => (xi === i ? n : x)) })} />
            )}
          </div>
        ))}
        {canEdit && site.sections.length < 20 && (
          <div className="flex flex-wrap gap-2">
            {SECTION_TYPES.filter((t) => !(t.type === 'hero' || t.type === 'events') || !site.sections.some((s) => s.type === t.type)).map((t) => (
              <button key={t.type} type="button" title={t.hint} className={BTN}
                onClick={() => update({ sections: [...site.sections, { type: t.type }] })}>
                <Plus className="w-3 h-3 inline mr-1" aria-hidden="true" />{t.label}
              </button>
            ))}
          </div>
        )}
        {canEdit && (
          <div className="flex items-center gap-3">
            <button type="button" onClick={() => void save()} disabled={busy || !dirty || !!err}
              className="px-4 py-2 bg-tm-blue text-white rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
              {busy ? 'Saving…' : 'Save website'}
            </button>
            {err && <span className="text-[11px] text-rose-600">{err}</span>}
          </div>
        )}
      </section>

      {canEdit && (
        <section>
          <h3 className="text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1">Your own domain</h3>
          <p className="text-[11px] text-slate-400 mb-3">
            e.g. tickets.yourvenue.com. Point it at {host || 'the Exos web host'} with a CNAME record, add the TXT record shown,
            then check. Its home page opens your storefront; the platform operator adds the domain to the web host for HTTPS.
          </p>
          <ul className="space-y-2 mb-3">
            {(domains ?? []).map((d) => (
              <li key={d.domain} className="border border-slate-200 rounded-xl p-3 text-xs text-slate-700">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-bold">{d.domain}</span>
                  <span className={d.status === 'verified' ? 'text-emerald-700' : d.status === 'failed' ? 'text-rose-600' : 'text-slate-500'}>
                    {d.status === 'verified' ? 'Verified' : d.status === 'failed' ? 'Not verified yet' : 'Pending'}
                  </span>
                </div>
                {d.status !== 'verified' && (
                  <p className="font-mono text-[11px] text-slate-500 mt-1 break-all">TXT {d.txtName} = {d.txtValue}</p>
                )}
                {d.lastError && <p className="text-[11px] text-rose-600 mt-1">{d.lastError}</p>}
                <div className="flex gap-2 mt-2">
                  <button type="button" className={BTN} onClick={async () => {
                    try {
                      const r = await verifyDomain(orgId, d.domain);
                      toast({ kind: r.ok ? 'success' : 'error', message: r.ok ? 'Verified.' : r.error ?? 'Not yet.' });
                    } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
                    loadDomains();
                  }}>Check</button>
                  <button type="button" className={BTN} onClick={async () => {
                    if (!window.confirm(`Remove ${d.domain}?`)) return;
                    try { await removeDomain(orgId, d.domain); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
                    loadDomains();
                  }}>Remove</button>
                </div>
              </li>
            ))}
          </ul>
          <div className="flex gap-2">
            <input className={FLD} value={newDomain} onChange={(e) => setNewDomain(e.target.value)} placeholder="tickets.yourvenue.com" />
            <button type="button" className={BTN} disabled={!newDomain.trim()} onClick={async () => {
              try { await addDomain(orgId, newDomain); setNewDomain(''); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
              loadDomains();
            }}>Add</button>
          </div>
        </section>
      )}

      <section>
        <h3 className="text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1">Widgets for your own site</h3>
        <p className="text-[11px] text-slate-400 mb-3">Paste into WordPress, Squarespace, Webflow or any HTML. The buy button and ticket box are on each event's Promote page.</p>
        <ul className="space-y-3">
          {widgetSnippets(loader, orgSlug).map((w) => (
            <li key={w.label}>
              <span className={LBL}>{w.label}</span>
              <div className="flex gap-2">
                <textarea readOnly rows={2} value={w.html} className={`${FLD} font-mono`} onClick={(e) => (e.target as HTMLTextAreaElement).select()} />
                <button type="button" className={BTN} onClick={() => void copy(w.html)}><Copy className="w-3 h-3" aria-hidden="true" /></button>
              </div>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
