// Accessible ticket options (mig 20260926090000) — shared UI: the needs
// picker (holder / staff / promoter), need badges, and the event access-info
// editor + public display. Vocabularies live in lib/accessibility.
import { useState } from 'react';
import { Accessibility as AccessIcon } from 'lucide-react';
import {
  ACCESS_CONTACT_MAX,
  ACCESS_FEATURES,
  ACCESS_NEEDS,
  ACCESS_NOTES_MAX,
  contactHref,
  featureLabel,
  hasAccessInfo,
  needShort,
  type AccessFeature,
  type AccessNeed,
  type EventAccessibility,
} from '../lib/accessibility';

type Theme = 'dark' | 'light';

/** Checkbox chips for access needs. Each chip is a real labelled checkbox. */
export function AccessNeedsPicker({
  value, onChange, theme = 'dark', disabled, idPrefix,
}: {
  value: AccessNeed[];
  onChange: (next: AccessNeed[]) => void;
  theme?: Theme;
  disabled?: boolean;
  idPrefix: string;
}) {
  const toggle = (id: AccessNeed, on: boolean) =>
    onChange(on ? Array.from(new Set([...value, id])).sort() as AccessNeed[] : value.filter((n) => n !== id));
  const chip = theme === 'dark'
    ? 'border-white/15 text-white/70 has-[:checked]:border-brand-primary has-[:checked]:text-white has-[:checked]:bg-brand-primary/10'
    : 'border-slate-200 text-slate-600 has-[:checked]:border-[#026cdf] has-[:checked]:text-slate-900 has-[:checked]:bg-blue-50';
  return (
    <fieldset className="grid grid-cols-1 sm:grid-cols-2 gap-2" disabled={disabled}>
      {ACCESS_NEEDS.map((n) => (
        <label key={n.id} htmlFor={`${idPrefix}-${n.id}`} className={`flex items-center gap-3 border px-3 py-2.5 text-sm cursor-pointer transition-colors ${chip}`}>
          <input
            id={`${idPrefix}-${n.id}`}
            type="checkbox"
            className="w-4 h-4 accent-brand-primary shrink-0"
            checked={value.includes(n.id)}
            onChange={(e) => toggle(n.id, e.target.checked)}
          />
          <span>{n.label}</span>
        </label>
      ))}
    </fieldset>
  );
}

/** Compact badges, e.g. on a door verdict or an attendee row. */
export function AccessNeedBadges({ needs, theme = 'light' }: { needs: string[]; theme?: Theme }) {
  if (!needs.length) return null;
  const cls = theme === 'dark'
    ? 'bg-sky-400/15 text-sky-200 border-sky-300/30'
    : 'bg-sky-50 text-sky-800 border-sky-200';
  return (
    <span className="inline-flex flex-wrap gap-1" aria-label={`Access needs: ${needs.map(needShort).join(', ')}`}>
      {needs.map((n) => (
        <span key={n} className={`inline-flex items-center gap-1 px-2 py-0.5 rounded border text-[11px] font-bold ${cls}`}>
          <AccessIcon className="w-3 h-3" aria-hidden="true" /> {needShort(n)}
        </span>
      ))}
    </span>
  );
}

/** Organizer editor for the event's access info (create + edit forms). */
export function EventAccessInfoEditor({
  value, onChange, idPrefix,
}: {
  value: EventAccessibility;
  onChange: (next: EventAccessibility) => void;
  idPrefix: string;
}) {
  const features = value.features ?? [];
  const setFeature = (id: AccessFeature, on: boolean) =>
    onChange({ ...value, features: on ? Array.from(new Set([...features, id])) : features.filter((f) => f !== id) });
  return (
    <div className="space-y-6">
      <fieldset>
        <legend className="type text-[11px] text-white/60 uppercase tracking-widest ml-1 mb-3">What the venue offers</legend>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
          {ACCESS_FEATURES.map((f) => (
            <label key={f.id} htmlFor={`${idPrefix}-f-${f.id}`} className="flex items-center gap-3 border border-white/15 px-3 py-2.5 text-sm text-white/70 cursor-pointer has-[:checked]:border-brand-primary has-[:checked]:text-white has-[:checked]:bg-brand-primary/10">
              <input
                id={`${idPrefix}-f-${f.id}`}
                type="checkbox"
                className="w-4 h-4 accent-brand-primary shrink-0"
                checked={features.includes(f.id)}
                onChange={(e) => setFeature(f.id, e.target.checked)}
              />
              <span>{f.label}</span>
            </label>
          ))}
        </div>
      </fieldset>
      <div className="space-y-2">
        <label htmlFor={`${idPrefix}-notes`} className="type text-[11px] text-white/60 uppercase tracking-widest ml-1">
          Access notes <span className="text-white/25 normal-case tracking-normal">(optional)</span>
        </label>
        <textarea
          id={`${idPrefix}-notes`}
          rows={3}
          maxLength={ACCESS_NOTES_MAX}
          placeholder="e.g. Step-free entrance on 5th St. The balcony is stairs only."
          className="w-full bg-black border border-white/20 py-3 px-4 text-white text-sm focus:outline-none focus:border-brand-primary"
          value={value.notes ?? ''}
          onChange={(e) => onChange({ ...value, notes: e.target.value })}
        />
      </div>
      <div className="space-y-2">
        <label htmlFor={`${idPrefix}-contact`} className="type text-[11px] text-white/60 uppercase tracking-widest ml-1">
          Access contact <span className="text-white/25 normal-case tracking-normal">(email or phone, optional)</span>
        </label>
        <input
          id={`${idPrefix}-contact`}
          type="text"
          maxLength={ACCESS_CONTACT_MAX}
          placeholder="access@yourvenue.com"
          className="w-full bg-black border border-white/20 py-3 px-4 text-white text-sm focus:outline-none focus:border-brand-primary"
          value={value.contact ?? ''}
          onChange={(e) => onChange({ ...value, contact: e.target.value })}
        />
      </div>
    </div>
  );
}

/** Public block on the event page. Renders nothing without info. */
export function EventAccessInfo({ accessibility }: { accessibility?: EventAccessibility }) {
  if (!hasAccessInfo(accessibility)) return null;
  const a = accessibility!;
  const href = a.contact ? contactHref(a.contact) : null;
  return (
    <section aria-labelledby="access-heading" className="border border-white/10 bg-[#111] p-6 md:p-8 mb-12">
      <h2 id="access-heading" className="disp text-2xl tracking-wide text-white mb-4 flex items-center gap-3">
        <AccessIcon className="w-5 h-5 text-brand-primary" aria-hidden="true" /> Accessibility
      </h2>
      {a.features && a.features.length > 0 && (
        <ul className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-2 mb-4">
          {a.features.map((f) => (
            <li key={f} className="type text-sm text-white/80 flex items-center gap-2">
              <span className="w-1.5 h-1.5 bg-brand-primary shrink-0" aria-hidden="true" /> {featureLabel(f)}
            </li>
          ))}
        </ul>
      )}
      {a.notes && <p className="type text-sm text-white/70 leading-relaxed whitespace-pre-line mb-4">{a.notes}</p>}
      {a.contact && (
        <p className="type text-sm text-white/60">
          Questions or a request?{' '}
          {href ? <a href={href} className="text-brand-primary underline underline-offset-2">{a.contact}</a> : <span className="text-white">{a.contact}</span>}
        </p>
      )}
      <p className="type text-xs text-white/40 mt-3">After you get your ticket, you can tell the organizer what you need from your pass.</p>
    </section>
  );
}

/** A guest row's needs: badges, plus an inline editor for whoever may edit. */
export function GuestAccessEditor({
  entryId, guestName, needs, canEdit, theme = 'light', onSave,
}: {
  entryId: string;
  guestName: string;
  needs: AccessNeed[];
  canEdit: boolean;
  theme?: Theme;
  onSave: (next: AccessNeed[]) => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState<AccessNeed[]>(needs);
  const [busy, setBusy] = useState(false);
  const btn = theme === 'dark'
    ? 'text-white/50 hover:text-white'
    : 'text-slate-500 hover:text-slate-900';
  if (!open) {
    return (
      <span className="flex flex-wrap items-center gap-2 mt-1">
        <AccessNeedBadges needs={needs} theme={theme} />
        {canEdit && (
          <button
            type="button"
            onClick={() => { setDraft(needs); setOpen(true); }}
            aria-label={`Access needs for ${guestName}`}
            className={`inline-flex items-center gap-1 text-[10px] font-bold uppercase tracking-widest ${btn}`}
          >
            <AccessIcon className="w-3 h-3" aria-hidden="true" /> {needs.length ? 'Edit access' : 'Access'}
          </button>
        )}
      </span>
    );
  }
  return (
    <div className="mt-2 space-y-2">
      <AccessNeedsPicker idPrefix={`ga-${entryId}`} value={draft} onChange={setDraft} theme={theme} disabled={busy} />
      <div className="flex gap-3">
        <button
          type="button"
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            // onSave shows its own error and rethrows so the editor stays open.
            try { await onSave(draft); setOpen(false); } catch { /* shown by caller */ } finally { setBusy(false); }
          }}
          className={theme === 'dark'
            ? 'px-3 py-2 bg-brand-primary text-black font-black text-[10px] uppercase tracking-widest disabled:opacity-40'
            : 'px-3 py-2 bg-slate-900 text-white rounded text-[10px] font-bold uppercase tracking-widest disabled:opacity-40'}
        >
          {busy ? 'Saving…' : 'Save'}
        </button>
        <button type="button" onClick={() => setOpen(false)} className={`text-[10px] font-bold uppercase tracking-widest ${btn}`}>Cancel</button>
      </div>
    </div>
  );
}
