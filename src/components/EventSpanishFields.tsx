// Edit event → Spanish (mig 20261114130000, docs/i18n-review.md): an optional
// Spanish title and description. Visitors who have the app in Spanish see them
// on the event page; blank fields fall back to the default title and
// description. Saved on its own (not with the main form), so the editor keeps
// working on a database without the column: the panel hides itself there.
// It sits inside the editor's <form>, so it has no form of its own.

import { useEffect, useState } from 'react';
import { Languages } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { getEventI18n, updateEventI18n } from '../lib/events';
import { EVENT_I18N_LIMITS, eventI18nPayload } from '../lib/i18n/dict';

const INPUT = 'type w-full bg-black border border-white/15 px-3 py-2.5 text-white text-sm focus:border-brand-primary outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

export default function EventSpanishFields({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [loaded, setLoaded] = useState<'loading' | 'ready' | 'absent'>('loading');
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let live = true;
    getEventI18n(eventId).then((v) => {
      if (!live) return;
      if (v === null) { setLoaded('absent'); return; }
      setTitle(v.es?.title ?? '');
      setDescription(v.es?.description ?? '');
      setLoaded('ready');
    }).catch(() => { if (live) setLoaded('absent'); });
    return () => { live = false; };
  }, [eventId]);

  if (loaded !== 'ready') return null;

  const save = async () => {
    setBusy(true);
    try {
      await updateEventI18n(eventId, eventI18nPayload({ title, description }));
      toast({ kind: 'success', message: 'Spanish version saved.' });
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save the Spanish version.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section data-testid="event-spanish-fields" aria-labelledby="ee-es-title" className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-5">
      <div>
        <h2 id="ee-es-title" className="disp text-lg uppercase tracking-wide text-white leading-none flex items-center gap-2">
          <Languages className="w-4 h-4" aria-hidden="true" /> Spanish version (optional)
        </h2>
        <p className="type text-xs text-white/60 mt-2">
          Shown to visitors who use Exos in Spanish. Leave a field blank to show the default one. Write it yourself or have
          a Spanish speaker check it: prices, fees and the refund policy are already shown in Spanish by Exos.
        </p>
      </div>
      <div className="space-y-4">
        <div>
          <label htmlFor="ee-es-name" className="type block text-[11px] text-white/70 uppercase tracking-widest mb-1.5">Title in Spanish</label>
          <input id="ee-es-name" lang="es" value={title} maxLength={EVENT_I18N_LIMITS.title}
            onChange={(e) => setTitle(e.target.value)} className={INPUT} />
        </div>
        <div>
          <label htmlFor="ee-es-desc" className="type block text-[11px] text-white/70 uppercase tracking-widest mb-1.5">Description in Spanish</label>
          <textarea id="ee-es-desc" lang="es" rows={5} value={description} maxLength={EVENT_I18N_LIMITS.description}
            onChange={(e) => setDescription(e.target.value)} className={INPUT} />
        </div>
        <button type="button" onClick={() => void save()} disabled={busy}
          className="type text-[11px] uppercase tracking-widest border border-white/20 px-4 py-2 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60">
          {busy ? 'Saving…' : 'Save Spanish version'}
        </button>
      </div>
    </section>
  );
}
