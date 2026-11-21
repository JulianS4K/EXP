// Posters and flyers (Promote page): one tracked QR code per spot a poster or
// flyer goes. Each placement's link is the event's short link tagged
// utm_source=qr, utm_medium=print, utm_content=<placement> (lib/printPlacements.ts),
// so Sources > "Placement / ad" shows what each spot sold. Stored in
// exos_print_placements (mig 20261121153700). The printable sheet of all the
// codes is /print/qr/:eventId.

import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { QRCodeCanvas } from 'qrcode.react';
import { Copy, Download, Printer, Trash2, MapPin } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { PLACEMENT_NAME_MAX, placementNameError, placementSheet, placementSlug, type PrintPlacement } from '../lib/printPlacements';
import { addPlacement, listPlacements, removePlacement } from '../lib/printPlacementsApi';

export default function PrintPlacementsPanel({ eventId, eventUrl, fileStem }: { eventId: string; eventUrl: string; fileStem: string }) {
  const { toast } = useToast();
  const [placements, setPlacements] = useState<PrintPlacement[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const qrRefs = useRef(new Map<string, HTMLDivElement | null>());

  const load = useCallback(() => {
    listPlacements(eventId)
      .then((p) => { setPlacements(p); setFailed(false); })
      .catch(() => { setPlacements([]); setFailed(true); });
  }, [eventId]);
  useEffect(load, [load]);

  const problem = name.trim() ? placementNameError(name) : null;
  const add = async () => {
    const err = placementNameError(name);
    if (err) { toast({ kind: 'error', message: err }); return; }
    setBusy(true);
    try {
      await addPlacement(eventId, name);
      setName('');
      load();
    } catch (e) {
      toast({ kind: 'error', message: e instanceof Error ? e.message : 'Could not add that placement.' });
    } finally {
      setBusy(false);
    }
  };
  const remove = async (p: PrintPlacement) => {
    if (!window.confirm(`Remove "${p.name}"? Sales it already brought in stay in your reports.`)) return;
    try {
      await removePlacement(p.id);
      load();
    } catch (e) {
      toast({ kind: 'error', message: e instanceof Error ? e.message : 'Could not remove it.' });
    }
  };
  const copy = async (url: string) => {
    try {
      await navigator.clipboard.writeText(url);
      toast({ kind: 'success', message: 'Link copied.' });
    } catch {
      toast({ kind: 'error', message: 'Could not copy: long-press to copy it.' });
    }
  };
  const download = (id: string, slug: string) => {
    const canvas = qrRefs.current.get(id)?.querySelector('canvas');
    if (!canvas) return;
    const a = document.createElement('a');
    a.href = canvas.toDataURL('image/png');
    a.download = `qr-${fileStem}-${slug}.png`;
    document.body.appendChild(a);
    a.click();
    a.remove();
  };

  const sheet = placementSheet(eventUrl, placements ?? []);

  return (
    <section data-promotion className="bg-[#111] p-6 border border-white/10 mb-6" aria-labelledby="placements-title">
      <h2 id="placements-title" className="disp text-lg uppercase tracking-wide text-white mb-1 flex items-center gap-2">
        <MapPin className="w-4 h-4 text-brand-primary" aria-hidden="true" /> Posters and flyers
      </h2>
      <p className="text-sm text-white/60 mb-4">
        Name each spot a poster or flyer goes. Each gets its own QR code, so the event's{' '}
        <Link to={`/dashboard/event/${eventId}`} className="text-brand-primary font-bold">Sources report</Link>{' '}
        (group by Placement) shows what each one sold.
      </p>
      <form className="flex flex-wrap gap-2 mb-1" onSubmit={(e) => { e.preventDefault(); void add(); }}>
        <label htmlFor="placement-name" className="sr-only">Placement name</label>
        <input id="placement-name" value={name} maxLength={PLACEMENT_NAME_MAX} onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Poster - Bedford Ave, Flyer - Bar X"
          aria-describedby="placement-hint"
          className="flex-1 min-w-[200px] bg-black border border-white/20 px-4 py-3 text-sm text-white placeholder:text-white/40 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60" />
        <button type="submit" disabled={busy || !name.trim() || !!problem}
          className="px-4 py-3 bg-brand-primary text-black text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
          Add placement
        </button>
      </form>
      <p id="placement-hint" className="text-[11px] text-white/50 mb-4">
        {problem ?? (name.trim() ? `Tracked as ${placementSlug(name)}` : 'Tagged utm_source=qr, utm_medium=print, utm_content=<the spot>.')}
      </p>

      {placements === null ? (
        <p className="text-white/50 text-sm">Loading…</p>
      ) : failed ? (
        <p className="text-white/50 text-sm">Placements aren't available yet.</p>
      ) : sheet.length === 0 ? (
        <p className="text-[11px] text-white/50 italic">No placements yet.</p>
      ) : (
        <>
          <ul className="divide-y divide-white/10 mb-4">
            {sheet.map((it) => (
              <li key={it.id} className="py-3 flex flex-wrap items-center gap-4">
                <div ref={(el) => { qrRefs.current.set(it.id, el); }} className="p-1.5 bg-white shrink-0">
                  <QRCodeCanvas value={it.url} size={72} level="M" marginSize={1} title={`QR code for ${it.name}`} />
                </div>
                <div className="min-w-0 flex-1">
                  <p className="font-bold text-sm text-white">{it.name}</p>
                  <p className="text-[11px] font-mono text-white/60 break-all">{it.url}</p>
                </div>
                <div className="flex items-center gap-1">
                  <button type="button" onClick={() => copy(it.url)} aria-label={`Copy link for ${it.name}`} className="p-2 text-white/60 hover:text-brand-primary"><Copy className="w-4 h-4" /></button>
                  <button type="button" onClick={() => download(it.id, it.slug)} aria-label={`Download QR for ${it.name}`} className="p-2 text-white/60 hover:text-brand-primary"><Download className="w-4 h-4" /></button>
                  <button type="button" onClick={() => remove(placements.find((p) => p.id === it.id)!)} aria-label={`Remove ${it.name}`} className="p-2 text-white/60 hover:text-red-400"><Trash2 className="w-4 h-4" /></button>
                </div>
              </li>
            ))}
          </ul>
          <Link to={`/print/qr/${eventId}`} target="_blank" rel="noopener"
            className="inline-flex items-center gap-2 px-4 py-2.5 border border-white/20 text-white text-[10px] font-black uppercase tracking-widest hover:border-brand-primary">
            <Printer className="w-3.5 h-3.5" aria-hidden="true" /> Printable QR sheet
          </Link>
        </>
      )}
    </section>
  );
}
