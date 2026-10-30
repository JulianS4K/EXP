// On the holder's ticket (mig 20261031210000): their matched-seats group.
// Before matching: the quiz (editable) and when groups form. After matching:
// "you're in a group of N", revealed at reveal time with the spot, the time
// and the others' first names. After meeting: "would meet again" (shown only
// when mutual), report and block. Renders nothing for an ordinary ticket.

import { useCallback, useEffect, useState } from 'react';
import { Flag, Heart, MapPin, Users, Ban } from 'lucide-react';
import {
  blockMember, clearTicketAnswers, getMyGroup, pickMember, reportMember, setTicketAnswers, type MyGroup,
} from '../lib/matchedSeatsApi';
import { answersBody, answersFromRow, type QuizAnswers } from '../lib/matchedSeats';
import MatchedQuiz from './MatchedQuiz';
import { useToast } from '../context/ToastContext';

function when(ms: number | null): string {
  if (!ms) return 'before the event';
  return new Date(ms).toLocaleString(undefined, {
    weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
  });
}

const REASONS: [string, string][] = [
  ['safety', 'I felt unsafe'], ['harassment', 'Harassment'], ['inappropriate', 'Inappropriate behaviour'],
  ['no_show', "Didn't show up"], ['other', 'Something else'],
];

export default function TicketMatchedGroup({ ticketId }: { ticketId: string }) {
  const { toast } = useToast();
  const [g, setG] = useState<MyGroup | null>(null);
  const [answers, setAnswers] = useState<QuizAnswers | null>(null);
  const [busy, setBusy] = useState(false);
  const [reporting, setReporting] = useState<string | null>(null);
  const [reason, setReason] = useState('safety');
  const [details, setDetails] = useState('');

  const load = useCallback(async () => {
    const r = await getMyGroup(ticketId);
    setG(r);
    if (r.state === 'waiting') setAnswers(answersFromRow(r.answers));
  }, [ticketId]);

  useEffect(() => { void load(); }, [load]);

  // Matched but hidden: look again shortly after the reveal time.
  useEffect(() => {
    if (g?.state !== 'matched' || !g.revealAt) return undefined;
    const wait = g.revealAt - Date.now() + 60_000;
    if (wait > 24 * 3600 * 1000) return undefined;
    const t = setTimeout(() => void load(), Math.max(wait, 60_000));
    return () => clearTimeout(t);
  }, [g, load]);

  if (!g || g.state === 'not_matched' || g.state === 'not_holder') return null;

  const run = async (fn: () => Promise<unknown>, ok?: string) => {
    setBusy(true);
    try {
      await fn();
      if (ok) toast({ kind: 'success', message: ok });
      await load();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Something went wrong.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="border border-white/10 bg-white/[0.03] p-5 mb-10 space-y-4" aria-label="Your group">
      <h3 className="type text-[11px] uppercase tracking-widest text-white/70 flex items-center gap-2">
        <Users className="w-4 h-4 text-brand-primary" aria-hidden="true" /> Your group
      </h3>

      {g.state === 'waiting' && (
        <>
          <p className="type text-sm text-white/70">
            Groups form {when(g.matchAt)}. Where you meet and who you're with is revealed {when(g.revealAt)}.
          </p>
          {g.quizEnabled && answers && (
            <>
              <MatchedQuiz value={answers} onChange={setAnswers} tags={g.quizTags} languages={g.quizLanguages} disabled={busy} />
              <div className="flex gap-3">
                <button type="button" disabled={busy} className="disp bg-brand-primary text-black px-5 py-2 text-sm"
                  onClick={() => void run(async () => {
                    await setTicketAnswers(ticketId, answersBody(answers, { tags: g.quizTags, languages: g.quizLanguages }));
                  }, 'Saved.')}>Save</button>
                <button type="button" disabled={busy} className="type text-xs text-white/50 underline"
                  onClick={() => void run(() => clearTicketAnswers(ticketId), 'Your answers were deleted.')}>
                  Delete my answers
                </button>
              </div>
            </>
          )}
        </>
      )}

      {g.state === 'matched' && (
        <p className="type text-sm text-white/70">
          You're in a group of {g.groupSize}. We'll tell you where and with whom {when(g.revealAt)}, here and by email
          (and by text if you get this organizer's texts).
        </p>
      )}

      {g.state === 'leftover' && (
        <p className="type text-sm text-white/70">
          {g.policy === 'refund'
            ? "We couldn't fit you in a group this time. The organizer will refund your ticket."
            : "We couldn't fit you in a group yet. The organizer will be in touch."}
        </p>
      )}

      {g.state === 'removed' && (
        <p className="type text-sm text-white/70">The organizer took you out of this group. Contact them with questions.</p>
      )}

      {g.state === 'revealed' && (
        <>
          {g.spot && (
            <div>
              <p className="disp text-lg text-white flex items-center gap-2">
                <MapPin className="w-4 h-4 text-brand-primary" aria-hidden="true" /> {g.spot.name}
              </p>
              {g.spot.address && <p className="type text-sm text-white/70">{g.spot.address}</p>}
              <p className="type text-sm text-white/70">{when(g.meetAt)}</p>
              {g.spot.details && <p className="type text-sm text-white/60 mt-1">{g.spot.details}</p>}
            </div>
          )}
          <ul className="space-y-2">
            {g.members.map((m) => (
              <li key={m.id} className="flex items-center justify-between gap-3 text-sm text-white">
                <span>
                  {m.firstName}{m.isMe ? ' (you)' : ''}
                  {m.mutual && <span className="ml-2 text-xs text-brand-primary">You both want to meet again</span>}
                </span>
                {!m.isMe && g.afterEvent && (
                  <span className="flex items-center gap-3">
                    <button type="button" disabled={busy} aria-pressed={m.picked}
                      title="Would meet again (they only see it if they pick you too)"
                      className={`flex items-center gap-1 text-xs ${m.picked ? 'text-brand-primary' : 'text-white/50'}`}
                      onClick={() => void run(() => pickMember(ticketId, m.id, !m.picked))}>
                      <Heart className="w-3.5 h-3.5" aria-hidden="true" /> Meet again
                    </button>
                    <button type="button" disabled={busy} className="flex items-center gap-1 text-xs text-white/50"
                      onClick={() => { setReporting(m.id); setReason('safety'); setDetails(''); }}>
                      <Flag className="w-3.5 h-3.5" aria-hidden="true" /> Report
                    </button>
                    <button type="button" disabled={busy} className="flex items-center gap-1 text-xs text-white/50"
                      onClick={() => {
                        if (!window.confirm(`Never group you with ${m.firstName} again?`)) return;
                        void run(() => blockMember(ticketId, m.id), 'Blocked. You won\'t be grouped together again.');
                      }}>
                      <Ban className="w-3.5 h-3.5" aria-hidden="true" /> Block
                    </button>
                  </span>
                )}
              </li>
            ))}
          </ul>
          {!g.afterEvent && (
            <p className="type text-[11px] text-white/40">After you've met you can say who you'd meet again; only mutual picks are shown.</p>
          )}
          {reporting && (
            <div className="border border-white/10 p-4 space-y-3">
              <p className="type text-sm text-white">Report to the organizer</p>
              <select className="w-full bg-black/40 border border-white/15 px-3 py-2 text-sm text-white"
                value={reason} onChange={(e) => setReason(e.target.value)}>
                {REASONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
              <textarea className="w-full bg-black/40 border border-white/15 px-3 py-2 text-sm text-white" rows={3}
                maxLength={1000} placeholder="What happened (optional)" value={details}
                onChange={(e) => setDetails(e.target.value)} />
              <div className="flex gap-3">
                <button type="button" disabled={busy} className="disp bg-brand-primary text-black px-4 py-2 text-sm"
                  onClick={() => {
                    const id = reporting;
                    setReporting(null);
                    void run(() => reportMember(ticketId, id, reason, details), 'Sent to the organizer.');
                  }}>Send</button>
                <button type="button" className="type text-xs text-white/50" onClick={() => setReporting(null)}>Cancel</button>
              </div>
            </div>
          )}
        </>
      )}
    </section>
  );
}
