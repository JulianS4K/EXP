// The optional matched-seats quiz (mig 20261031210000). Every field can be
// left blank. Asks for an age band (never a birthdate), a language, interests
// from the organizer's list, solo / with friends, a party code for friends
// buying separately, and the first name the group will see.

import { AGE_BANDS, newPartyCode, type QuizAnswers } from '../lib/matchedSeats';

function languageName(code: string): string {
  try {
    return new Intl.DisplayNames(undefined, { type: 'language' }).of(code) ?? code;
  } catch {
    return code;
  }
}

const field = 'w-full bg-black/40 border border-white/15 px-3 py-2 text-sm text-white';

export default function MatchedQuiz({
  value, onChange, tags, languages, disabled = false,
}: {
  value: QuizAnswers;
  onChange: (next: QuizAnswers) => void;
  tags: string[];
  languages: string[];
  disabled?: boolean;
}) {
  const set = (patch: Partial<QuizAnswers>) => onChange({ ...value, ...patch });
  const toggleTag = (t: string) => {
    const has = value.tags.includes(t);
    if (!has && value.tags.length >= 5) return;
    set({ tags: has ? value.tags.filter((x) => x !== t) : [...value.tags, t] });
  };

  return (
    <fieldset className="space-y-4" disabled={disabled}>
      <legend className="type text-[11px] text-white/60 uppercase tracking-widest mb-2">
        Help us seat you well (optional)
      </legend>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <label className="block">
          <span className="type text-xs text-white/60">First name your group sees</span>
          <input className={field} maxLength={40} value={value.displayName} autoComplete="given-name"
            onChange={(e) => set({ displayName: e.target.value })} />
        </label>
        <label className="block">
          <span className="type text-xs text-white/60">Age range</span>
          <select className={field} value={value.ageBand} onChange={(e) => set({ ageBand: e.target.value })}>
            <option value="">Rather not say</option>
            {AGE_BANDS.map((b) => <option key={b} value={b}>{b}</option>)}
          </select>
        </label>
        {languages.length > 1 && (
          <label className="block">
            <span className="type text-xs text-white/60">Language at the table</span>
            <select className={field} value={value.language} onChange={(e) => set({ language: e.target.value })}>
              <option value="">Any</option>
              {languages.map((l) => <option key={l} value={l}>{languageName(l)}</option>)}
            </select>
          </label>
        )}
        <label className="block">
          <span className="type text-xs text-white/60">Coming</span>
          <select className={field} value={value.mode}
            onChange={(e) => set({ mode: e.target.value as QuizAnswers['mode'] })}>
            <option value="">Rather not say</option>
            <option value="solo">Solo</option>
            <option value="friends">With friends</option>
          </select>
        </label>
      </div>
      {tags.length > 0 && (
        <div>
          <span className="type text-xs text-white/60">Into (up to 5)</span>
          <div className="flex flex-wrap gap-2 mt-2">
            {tags.map((t) => {
              const on = value.tags.includes(t);
              return (
                <button key={t} type="button" aria-pressed={on} onClick={() => toggleTag(t)}
                  className={`px-3 py-1 text-xs border ${on ? 'border-brand-primary text-brand-primary' : 'border-white/15 text-white/70'}`}>
                  {t}
                </button>
              );
            })}
          </div>
        </div>
      )}
      <div>
        <span className="type text-xs text-white/60">Party code: friends who buy separately and use the same code sit together</span>
        <div className="flex gap-2 mt-1">
          <input className={field} maxLength={14} value={value.partyCode} placeholder="e.g. K7Q2MX"
            onChange={(e) => set({ partyCode: e.target.value.toUpperCase() })} />
          <button type="button" className="px-3 text-xs border border-white/15 text-white/80 whitespace-nowrap"
            onClick={() => set({ partyCode: newPartyCode() })}>New code</button>
        </div>
        <p className="type text-[11px] text-white/40 mt-1">Tickets in one order always sit together.</p>
      </div>
      <p className="type text-[11px] text-white/40">
        Used only to form groups, never shown to other guests except your first name, and deleted after the event.
      </p>
    </fieldset>
  );
}
