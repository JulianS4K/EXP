// Platform limit notes (channel core, mig 20261121162400; limits.ts is the
// single source): what a platform's rules say about this event / ticket
// type, for the allocation grid (MarketplaceGrid) and the recommended
// channels (the promotion views point here once merged).
// block: Exos won't send it there; cap: capped; warn: goes ahead.

import { notesFor, type LimitFacts, type LimitNote, type UsageReadings } from '../../supabase/functions/_shared/channels/limits.ts';

const LIGHT = { block: 'text-rose-800 bg-rose-50', cap: 'text-sky-800 bg-sky-50', warn: 'text-amber-800 bg-amber-50' } as const;
const DARK = { block: 'text-rose-300 border border-rose-400/40', cap: 'text-sky-300 border border-sky-400/40', warn: 'text-amber-300 border border-amber-400/40' } as const;

/** The platforms among `platforms` whose rules block these facts. */
export function blockedOn(platforms: readonly string[], facts: LimitFacts): string[] {
  return platforms.filter((p) => notesFor(p, facts).some((n) => n.action === 'block'));
}

export function LimitNoteList({ notes, label, tone = 'light' }: { notes: LimitNote[]; label?: string; tone?: 'light' | 'dark' }) {
  if (!notes.length) return null;
  const cls = tone === 'dark' ? DARK : LIGHT;
  return (
    <ul className="space-y-1" aria-label="Platform rules">
      {notes.map((n) => (
        <li key={`${n.platform}:${n.ruleId}`} role="note" data-action={n.action} className={`text-[11px] rounded px-2 py-1 ${cls[n.action]}`}>
          {label ? <span className="font-bold">{label}: </span> : null}{n.text}
        </li>
      ))}
    </ul>
  );
}

export default function ChannelLimitNotes({ platform, facts, usage, label, tone }: {
  platform: string;
  facts: LimitFacts;
  usage?: UsageReadings;
  label?: string;
  tone?: 'light' | 'dark';
}) {
  return <LimitNoteList notes={notesFor(platform, facts, usage ?? {})} label={label} tone={tone} />;
}
