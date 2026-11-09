// A ticket's checkout answers at the door (mig 20261106110000): "needs
// wheelchair access", "T-shirt size: M". Door staff read the per-ticket
// answers of their event (RLS), and can add or correct one, hidden questions
// included (exos_door_set_ticket_answers; nothing is required at the door).
// Hidden when there's nothing to show or the database predates the migration.

import { useEffect, useState } from 'react';
import { validateAnswers, type QuestionDef } from '../../supabase/functions/_shared/questions.ts';
import {
  listEventQuestions, listTicketAnswers, setTicketAnswersAtDoor, type AnswerDraft, type RawAnswer, type TicketAnswer,
} from '../lib/checkoutQuestions';
import CheckoutQuestionsForm from './CheckoutQuestionsForm';

export default function TicketAnswersCard({ ticketId, eventId, tierId }: { ticketId: string; eventId: string; tierId?: string | null }) {
  const [answers, setAnswers] = useState<TicketAnswer[] | null>(null);
  const [editing, setEditing] = useState(false);
  const [qs, setQs] = useState<QuestionDef[]>([]);
  const [draft, setDraft] = useState<AnswerDraft>({ order: {}, tickets: [{}] });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setAnswers(null); setEditing(false); setError(null);
    listTicketAnswers(ticketId).then((a) => { if (live) setAnswers(a); }).catch(() => { if (live) setAnswers([]); });
    // Per-ticket questions the door may fill (hidden ones too).
    listEventQuestions(eventId)
      .then((all) => {
        if (!live) return;
        setQs(all.filter((q) => !q.archived && q.scope === 'ticket'
          && (!q.tier_ids || q.tier_ids.length === 0 || (tierId ? q.tier_ids.includes(tierId) : false))));
      })
      .catch(() => { if (live) setQs([]); });
    return () => { live = false; };
  }, [ticketId, eventId, tierId]);

  const tiers = [tierId ?? '00000000-0000-0000-0000-000000000000'];
  const check = validateAnswers(qs, draft, { ticketTiers: tiers, require: false });
  const problems: Record<string, (typeof check.problems)[number]> = {};
  for (const p of check.problems) problems[`${p.ticket ?? 'order'}:${p.question_id ?? ''}`] = p;

  const startEdit = () => {
    const t: Record<string, RawAnswer> = {};
    for (const a of answers ?? []) if (a.scope === 'ticket') t[a.question_id] = a.value as RawAnswer;
    setDraft({ order: {}, tickets: [t] });
    setEditing(true);
  };

  const save = async () => {
    if (!check.ok) return;
    setSaving(true); setError(null);
    try {
      // Every per-ticket question: a value, or '' to clear it.
      const body: Record<string, RawAnswer> = {};
      for (const q of qs) body[q.id] = draft.tickets[0]?.[q.id] ?? '';
      await setTicketAnswersAtDoor(ticketId, body);
      setAnswers(await listTicketAnswers(ticketId));
      setEditing(false);
    } catch (e) {
      setError((e as Error)?.message || 'Could not save.');
    } finally {
      setSaving(false);
    }
  };

  if (answers === null || (answers.length === 0 && qs.length === 0)) return null;

  return (
    <div className="w-full p-4 bg-white rounded-2xl border border-green-50 text-left" data-testid="door-answers">
      <div className="flex items-center justify-between mb-2">
        <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-none">Answers</p>
        {qs.length > 0 && !editing && (
          <button type="button" onClick={startEdit} className="text-[11px] font-bold text-slate-500 underline">
            {answers.some((a) => a.scope === 'ticket') ? 'Change' : 'Add'}
          </button>
        )}
      </div>
      {!editing && (answers.length === 0
        ? <p className="text-xs text-slate-400">No answers yet.</p>
        : (
          <dl className="space-y-1">
            {answers.map((a) => (
              <div key={`${a.scope}-${a.question_id}`} className="flex gap-2 text-sm">
                <dt className="text-slate-500 shrink-0">{a.label}:</dt>
                <dd className="font-bold text-slate-900 break-words">{a.display}</dd>
              </div>
            ))}
          </dl>
        ))}
      {editing && (
        <div>
          <CheckoutQuestionsForm questions={qs} ticketTiers={tiers} value={draft} onChange={setDraft} problems={problems} showErrors tone="light" />
          {error && <p role="alert" className="text-xs text-rose-600 mb-2">{error}</p>}
          <div className="flex gap-2">
            <button type="button" disabled={saving || !check.ok} onClick={save}
              className="px-4 py-2 rounded-xl bg-slate-900 text-white text-xs font-bold disabled:opacity-50">{saving ? 'Saving…' : 'Save answers'}</button>
            <button type="button" onClick={() => setEditing(false)} className="px-4 py-2 rounded-xl border border-slate-200 text-xs font-bold text-slate-600">Cancel</button>
          </div>
        </div>
      )}
    </div>
  );
}
