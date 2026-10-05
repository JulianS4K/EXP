// The "How people attend" section of the event form (mig 20261005090000),
// shared by CreateEvent and EditEvent: in person / online / hybrid, the
// private join link (only ticket holders see it), what to bring, and the
// "hide from search engines" switch. Pure form state (lib/onlineEvents
// OnlineDraft); the parent saves it.

import {
  EVENT_FORMATS, JOIN_NOTE_MAX, REVEAL_OPTIONS, WHAT_TO_BRING_MAX, isJoinUrl, isOnline, type OnlineDraft,
} from '../lib/onlineEvents';

const LABEL = 'type text-[11px] text-white/60 uppercase tracking-widest ml-1';
const HINT = 'type text-[9px] text-white/30 uppercase tracking-widest ml-1';
const INPUT = 'w-full bg-black border border-white/20 py-3 px-4 text-white text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary';

export default function OnlineEventEditor({
  value, onChange, idPrefix, linkLocked = false,
}: {
  value: OnlineDraft;
  onChange: (next: OnlineDraft) => void;
  idPrefix: string;
  // Edit form: the saved link hasn't loaded (or couldn't be read), so its
  // fields are read-only rather than silently not saving.
  linkLocked?: boolean;
}) {
  const set = <K extends keyof OnlineDraft>(k: K, v: OnlineDraft[K]) => onChange({ ...value, [k]: v });
  const online = isOnline(value.format);
  const urlBad = online && value.joinUrl.trim() !== '' && !isJoinUrl(value.joinUrl);

  return (
    <div className="space-y-6">
      <fieldset>
        <legend className={`${LABEL} mb-3`}>How people attend</legend>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
          {EVENT_FORMATS.map((f) => (
            <label
              key={f.id}
              htmlFor={`${idPrefix}-format-${f.id}`}
              className="flex items-start gap-3 border border-white/15 px-3 py-2.5 text-sm text-white/70 cursor-pointer has-[:checked]:border-brand-primary has-[:checked]:text-white has-[:checked]:bg-brand-primary/10"
            >
              <input
                id={`${idPrefix}-format-${f.id}`}
                type="radio"
                name={`${idPrefix}-format`}
                className="mt-0.5 w-4 h-4 accent-brand-primary shrink-0"
                checked={value.format === f.id}
                onChange={() => set('format', f.id)}
              />
              <span>
                <span className="block">{f.label}</span>
                <span className="block text-[11px] text-white/40">{f.hint}</span>
              </span>
            </label>
          ))}
        </div>
      </fieldset>

      {online && (
        <fieldset disabled={linkLocked} className="space-y-4 border-l-2 border-brand-primary/40 pl-4 disabled:opacity-50">
          <div className="space-y-2">
            <label htmlFor={`${idPrefix}-join-url`} className={LABEL}>
              Join link <span className="text-white/25 normal-case tracking-normal">(stream, Zoom, Discord; optional for now)</span>
            </label>
            <input
              id={`${idPrefix}-join-url`}
              type="url"
              inputMode="url"
              placeholder="https://"
              className={INPUT}
              aria-invalid={urlBad}
              aria-describedby={`${idPrefix}-join-help`}
              value={value.joinUrl}
              onChange={(e) => set('joinUrl', e.target.value)}
            />
            {urlBad && <p className="text-xs text-red-400 ml-1">Use an https:// link.</p>}
            <p id={`${idPrefix}-join-help`} className="type text-[11px] text-white/40 ml-1">
              Private: only people holding a ticket see it, on their ticket in the app. It's never emailed or shown on the event page.
            </p>
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div className="space-y-2">
              <label htmlFor={`${idPrefix}-join-note`} className={LABEL}>
                Joining instructions <span className="text-white/25 normal-case tracking-normal">(optional)</span>
              </label>
              <input
                id={`${idPrefix}-join-note`}
                type="text"
                maxLength={JOIN_NOTE_MAX}
                placeholder="e.g. Passcode 4242. Cameras optional."
                className={INPUT}
                value={value.joinNote}
                onChange={(e) => set('joinNote', e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <label htmlFor={`${idPrefix}-reveal`} className={LABEL}>Show the link</label>
              <select
                id={`${idPrefix}-reveal`}
                className={INPUT}
                value={value.reveal}
                onChange={(e) => set('reveal', e.target.value)}
              >
                {REVEAL_OPTIONS.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
              </select>
            </div>
          </div>
        </fieldset>
      )}

      <div className="space-y-2">
        <label htmlFor={`${idPrefix}-bring`} className={LABEL}>
          What to bring <span className="text-white/25 normal-case tracking-normal">(optional)</span>
        </label>
        <textarea
          id={`${idPrefix}-bring`}
          rows={2}
          maxLength={WHAT_TO_BRING_MAX}
          placeholder={online ? 'e.g. Headphones and a good connection.' : 'e.g. Photo ID. Bags no bigger than 12 × 12 in.'}
          className={`${INPUT} resize-y`}
          value={value.whatToBring}
          onChange={(e) => set('whatToBring', e.target.value)}
        />
        <p className={HINT}>
          On the event page, the ticket and the reminder email · {value.whatToBring.length} / {WHAT_TO_BRING_MAX}
        </p>
      </div>

      <label htmlFor={`${idPrefix}-noindex`} className="flex items-start gap-3 text-sm text-white/70 cursor-pointer">
        <input
          id={`${idPrefix}-noindex`}
          type="checkbox"
          className="mt-0.5 w-4 h-4 accent-brand-primary shrink-0"
          checked={value.noindex}
          onChange={(e) => set('noindex', e.target.checked)}
        />
        <span>
          Hide from search engines
          <span className="block text-[11px] text-white/40">
            Keeps the event out of Google, the sitemap and public feeds. Anyone with the link can still open it.
          </span>
        </span>
      </label>
    </div>
  );
}
