// Organizer dashboard → "List an event you sell elsewhere" (mig 20261029170000;
// docs/organizer-guide.md). Two ways in:
//   * From the connected Eventbrite account: pick one or many, imported
//     published (re-importing one updates it).
//   * Paste an Eventbrite, Luma or Posh link. Eventbrite is read through its
//     API; Luma and Posh become a draft from the details typed here (Exos
//     doesn't read their pages yet).
// Exos lists the event and sends buyers to that checkout; it sells nothing.

import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Download } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { getBrowserTimezone, zonedWallClockToUtc } from '../lib/datetime';
import {
  importEventbriteEvents, importFromLink, linkOutPriceLabel, listEventbriteImports, nameFromSlug, parseEventUrl,
  platformLabel, type ImportChoice, type ImportResult, type ParsedEventUrl,
} from '../lib/linkOut';

const BTN = 'bg-white text-slate-900 border border-slate-200 px-4 py-2 rounded font-bold text-sm hover:bg-slate-50 disabled:opacity-40';
const PRIMARY = 'bg-[#026cdf] text-white px-4 py-2 rounded font-bold text-sm hover:bg-[#015bbd] disabled:opacity-40';
const FLD = 'w-full border border-slate-300 rounded px-3 py-2 text-sm text-slate-900';

export default function ImportEventsPanel({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [choices, setChoices] = useState<ImportChoice[] | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [results, setResults] = useState<ImportResult[]>([]);
  const [link, setLink] = useState('');
  const [parsed, setParsed] = useState<ParsedEventUrl | null>(null);
  const [draft, setDraft] = useState({ name: '', start: '', venue: '', city: '', country: '', priceMin: '', priceMax: '', currency: 'USD', image: '' });

  const fail = (e: unknown) => toast({ kind: 'error', message: e instanceof Error ? e.message : 'Something went wrong.' });

  const loadEventbrite = async () => {
    setBusy(true);
    try {
      const list = await listEventbriteImports(orgId);
      setChoices(list);
      setPicked(new Set());
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
    }
  };

  const importPicked = async () => {
    setBusy(true);
    try {
      const out = await importEventbriteEvents(orgId, [...picked]);
      setResults(out);
      const ok = out.filter((r) => r.ok).length;
      toast({ kind: ok ? 'success' : 'error', message: `${ok} of ${out.length} listed.` });
      await loadEventbrite();
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
    }
  };

  const onLink = (v: string) => {
    setLink(v);
    const p = parseEventUrl(v);
    const next = 'error' in p ? null : p;
    setParsed(next);
    if (next && !draft.name) setDraft((d) => ({ ...d, name: nameFromSlug(next) }));
  };

  const submitLink = async () => {
    if (!parsed) return;
    setBusy(true);
    try {
      const num = (s: string) => (s.trim() === '' || !Number.isFinite(Number(s)) ? undefined : Number(s));
      const tz = getBrowserTimezone();
      const start = draft.start ? zonedWallClockToUtc(draft.start, tz) : null;
      const r = parsed.platform === 'eventbrite'
        ? await importFromLink(orgId, link)
        : await importFromLink(orgId, link, {
            name: draft.name.trim(),
            ...(start ? { starts_at: start.toISOString(), timezone: tz } : {}),
            ...(draft.venue.trim() ? { venue_name: draft.venue.trim() } : {}),
            ...(draft.city.trim() ? { city: draft.city.trim() } : {}),
            ...(draft.country.trim() ? { country: draft.country.trim() } : {}),
            ...(num(draft.priceMin) !== undefined ? { price_min: num(draft.priceMin) } : {}),
            ...(num(draft.priceMax) !== undefined ? { price_max: num(draft.priceMax) } : {}),
            currency: draft.currency.trim().toUpperCase() || 'USD',
            ...(draft.image.trim() ? { image_url: draft.image.trim() } : {}),
          });
      setResults([r]);
      if (r.ok) {
        toast({ kind: 'success', message: r.status === 'draft' ? 'Draft created: check it and publish.' : 'Listed.' });
        setLink('');
        setParsed(null);
      } else fail(new Error(r.error ?? 'Not imported.'));
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
    }
  };

  if (!open) {
    return (
      <button type="button" onClick={() => setOpen(true)} className={`${BTN} flex items-center gap-2 mb-8`}>
        <Download className="w-4 h-4" /> List an event you sell elsewhere
      </button>
    );
  }

  return (
    <section className="mb-8 bg-white border border-slate-200 rounded p-6 shadow-sm" aria-labelledby="import-events-h">
      <div className="flex items-start justify-between gap-4 mb-4">
        <div>
          <h2 id="import-events-h" className="font-black text-slate-900 text-lg">List an event you sell elsewhere</h2>
          <p className="text-sm text-slate-600 max-w-2xl">
            Exos lists it (event page, your organizer page, Google, calendars, catalog feeds) and sends buyers to your own
            Eventbrite, Luma or Posh checkout. Exos sells nothing for it and charges nothing.
          </p>
        </div>
        <button type="button" onClick={() => setOpen(false)} className="text-sm text-slate-500 hover:text-slate-900">Close</button>
      </div>

      <div className="grid gap-6 md:grid-cols-2">
        <div>
          <h3 className="font-bold text-slate-900 text-sm mb-2">From your Eventbrite account</h3>
          <button type="button" className={BTN} disabled={busy} onClick={loadEventbrite}>
            {choices ? 'Refresh' : 'Show my Eventbrite events'}
          </button>
          {choices && choices.length === 0 && <p className="text-sm text-slate-500 mt-3">No live or upcoming events on this Eventbrite account.</p>}
          {choices && choices.length > 0 && (
            <>
              <ul className="mt-3 divide-y divide-slate-100 border border-slate-200 rounded max-h-80 overflow-auto">
                {choices.map((c) => (
                  <li key={c.id} className="flex items-center gap-3 px-3 py-2 text-sm">
                    <input type="checkbox" aria-label={`Import ${c.name}`} disabled={busy || picked.size >= 25 && !picked.has(c.id)}
                      checked={picked.has(c.id)}
                      onChange={(e) => setPicked((s) => { const n = new Set(s); if (e.target.checked) n.add(c.id); else n.delete(c.id); return n; })} />
                    <span className="flex-1 min-w-0">
                      <span className="block font-bold text-slate-900 truncate">{c.name}</span>
                      <span className="block text-xs text-slate-500 truncate">
                        {[c.start ? new Date(c.start).toLocaleString() : null, c.venue,
                          linkOutPriceLabel({ priceMin: c.priceMin, priceMax: c.priceMax, isFree: false, currency: c.currency }),
                          c.status === 'sold_out' ? 'sold out' : null].filter(Boolean).join(' · ')}
                      </span>
                    </span>
                    {c.importedEventId && <Link to={`/edit-event/${c.importedEventId}`} className="text-xs text-[#026cdf] shrink-0">listed ✓</Link>}
                  </li>
                ))}
              </ul>
              <button type="button" className={`${PRIMARY} mt-3`} disabled={busy || picked.size === 0} onClick={importPicked}>
                List {picked.size || ''} on Exos
              </button>
              <p className="text-xs text-slate-500 mt-1">Already listed ones are updated, not duplicated. Up to 25 at a time.</p>
            </>
          )}
        </div>

        <div>
          <h3 className="font-bold text-slate-900 text-sm mb-2">Paste an event link</h3>
          <input className={FLD} placeholder="https://www.eventbrite.com/e/… · https://lu.ma/… · https://posh.vip/e/…"
            value={link} onChange={(e) => onLink(e.target.value)} aria-label="Event link" />
          {link && !parsed && <p className="text-xs text-red-600 mt-1">{(parseEventUrl(link) as { error?: string }).error}</p>}
          {parsed && parsed.platform === 'eventbrite' && (
            <p className="text-xs text-slate-500 mt-1">Eventbrite event {parsed.sourceId}: Exos reads it with your connected Eventbrite account.</p>
          )}
          {parsed && parsed.platform !== 'eventbrite' && (
            <div className="mt-3 space-y-2">
              <p className="text-xs text-slate-500">
                Exos doesn't read {platformLabel(parsed.platform)} pages yet: fill in the details. It's saved as a draft for you to check and publish.
              </p>
              <input className={FLD} placeholder="Event name" aria-label="Event name" value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} />
              <input className={FLD} type="datetime-local" aria-label="Starts (your time zone)" value={draft.start} onChange={(e) => setDraft({ ...draft, start: e.target.value })} />
              <div className="grid grid-cols-3 gap-2">
                <input className={FLD} placeholder="Venue" aria-label="Venue" value={draft.venue} onChange={(e) => setDraft({ ...draft, venue: e.target.value })} />
                <input className={FLD} placeholder="City" aria-label="City" value={draft.city} onChange={(e) => setDraft({ ...draft, city: e.target.value })} />
                <input className={FLD} placeholder="Country" aria-label="Country" value={draft.country} onChange={(e) => setDraft({ ...draft, country: e.target.value })} />
              </div>
              <div className="grid grid-cols-3 gap-2">
                <input className={FLD} inputMode="decimal" placeholder="Price from" aria-label="Price from" value={draft.priceMin} onChange={(e) => setDraft({ ...draft, priceMin: e.target.value })} />
                <input className={FLD} inputMode="decimal" placeholder="Price to" aria-label="Price to" value={draft.priceMax} onChange={(e) => setDraft({ ...draft, priceMax: e.target.value })} />
                <input className={FLD} maxLength={3} placeholder="USD" aria-label="Currency" value={draft.currency} onChange={(e) => setDraft({ ...draft, currency: e.target.value })} />
              </div>
              <input className={FLD} placeholder="Image link (https)" aria-label="Image link" value={draft.image} onChange={(e) => setDraft({ ...draft, image: e.target.value })} />
            </div>
          )}
          <button type="button" className={`${PRIMARY} mt-3`} onClick={submitLink}
            disabled={busy || !parsed || (parsed.platform !== 'eventbrite' && !draft.name.trim())}>
            {parsed && parsed.platform !== 'eventbrite' ? 'Create draft' : 'List on Exos'}
          </button>
        </div>
      </div>

      {results.length > 0 && (
        <ul className="mt-4 text-sm space-y-1" aria-live="polite">
          {results.map((r, i) => (
            <li key={r.eventId ?? r.id ?? i} className={r.ok ? 'text-slate-700' : 'text-red-600'}>
              {r.ok && r.eventId
                ? <>{r.created ? 'Listed' : 'Updated'} ({r.status}) · <Link className="text-[#026cdf]" to={`/edit-event/${r.eventId}`}>open</Link></>
                : `${r.id ? `${r.id}: ` : ''}${r.error ?? 'Not imported.'}`}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
