// The answers to an event's checkout questions (mig 20261106110000), in the
// event report: one row per answer of every issued order, filterable by
// question, with a CSV (owner / manager / finance: exos_event_question_answers;
// hidden for anyone else and before the migration). The label is the one the
// buyer saw; a renamed or archived question says so.

import { useEffect, useMemo, useState } from 'react';
import { Download, HelpCircle } from 'lucide-react';
import { csvFileName, downloadCsv } from '../lib/csv';
import { answersCsv, listEventAnswers, type AnswerRow } from '../lib/checkoutQuestions';

export default function QuestionAnswersPanel({ eventId, eventTitle, canView }: { eventId: string; eventTitle: string; canView: boolean }) {
  const [rows, setRows] = useState<AnswerRow[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [question, setQuestion] = useState('');

  useEffect(() => {
    if (!canView) return undefined;
    let live = true;
    listEventAnswers(eventId)
      .then((r) => { if (live) setRows(r); })
      .catch((e) => { console.error('exos_event_question_answers failed:', e); if (live) setFailed(true); });
    return () => { live = false; };
  }, [eventId, canView]);

  const questions = useMemo(() => {
    const m = new Map<string, string>();
    for (const r of rows ?? []) if (!m.has(r.question_id)) m.set(r.question_id, r.current_label + (r.question_archived ? ' (archived)' : ''));
    return [...m.entries()];
  }, [rows]);
  const shown = (rows ?? []).filter((r) => !question || r.question_id === question);

  if (!canView || failed || rows === null || rows.length === 0) return null;

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6" data-testid="question-answers">
      <div className="flex flex-wrap items-center justify-between gap-3 mb-1">
        <h3 className="text-sm font-bold text-slate-700 flex items-center gap-2">
          <HelpCircle size={14} aria-hidden="true" /> Checkout answers
        </h3>
        <div className="flex items-center gap-2">
          {questions.length > 1 && (
            <select aria-label="Show answers to" value={question} onChange={(e) => setQuestion(e.target.value)}
              className="text-xs border border-slate-200 rounded-lg px-2 py-1.5">
              <option value="">All questions</option>
              {questions.map(([id, label]) => <option key={id} value={id}>{label}</option>)}
            </select>
          )}
          <button type="button" onClick={() => downloadCsv(csvFileName(['answers', eventTitle]), answersCsv(shown))}
            className="inline-flex items-center gap-1 px-3 py-2 bg-slate-50 hover:bg-slate-100 rounded text-[10px] font-bold uppercase tracking-widest border border-slate-200">
            <Download size={12} aria-hidden="true" /> Answers CSV
          </button>
        </div>
      </div>
      <p className="text-xs text-slate-400 mb-4">What buyers answered at checkout (and staff at the door), per order and per ticket.</p>
      <div className="overflow-x-auto max-h-[480px] overflow-y-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
              <th className="py-2 font-black">Order / ticket</th>
              <th className="py-2 font-black">Question</th>
              <th className="py-2 font-black">Answer</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((r) => (
              <tr key={r.answer_id} className="border-b border-slate-50 last:border-b-0 align-top">
                <td className="py-2 pr-3 text-slate-700">
                  <span className="block text-sm">{r.attendee_name || r.buyer_email || 'Order'}</span>
                  <span className="block text-slate-400 text-[10px]">
                    {r.scope === 'ticket' ? `Ticket ${r.ticket_index ?? '?'}${r.tier_name ? ` · ${r.tier_name}` : ''}` : 'Whole order'}
                    {r.ticket_status && r.ticket_status !== 'active' ? ` · ${r.ticket_status}` : ''}
                    <span className="font-mono"> · {r.order_ref.slice(0, 14)}</span>
                  </span>
                </td>
                <td className="py-2 pr-3 text-slate-700">
                  {r.label}
                  {(r.current_label !== r.label || r.question_archived) && (
                    <span className="block text-[10px] text-slate-400">
                      {r.question_archived ? 'archived' : `now "${r.current_label}"`}
                    </span>
                  )}
                </td>
                <td className="py-2 text-slate-900 font-semibold break-words">{r.display}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
