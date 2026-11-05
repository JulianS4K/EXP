// Checkout questions builder (mig 20261106110000, docs/checkout-questions.md),
// embedded in EditEvent next to the add-ons. Self-contained like
// AddonsEditor: its own load / save through the owner / manager RPCs
// (exos_save_event_question, exos_archive_event_question,
// exos_reorder_event_questions), not part of the event form submit.
//
// Add, edit, reorder (up / down), limit to ticket types, hide (not asked at
// checkout, staff fill it at the door), archive ("delete": answers are kept)
// and restore, and a live preview of what buyers see. A question with answers
// keeps its type and per order / per ticket (the server refuses a change).
//
// "Show only if…" (mig 20261107110000): a question can depend on a choice or
// checkbox question of the event (per order; or, for a per-ticket question,
// per ticket too) and is asked only when that one is answered with one of the
// picked options (a checkbox: when ticked). The builder checks what the
// server checks (conditionProblem); a parent with questions depending on it
// can't be archived until they are changed.

import { useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, Archive, Eye, EyeOff, HelpCircle, Pencil, Plus, RotateCcw } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  CHOICE_KINDS, CONDITION_PARENT_KINDS, QUESTION_KINDS, conditionProblem, questionDefProblem, type QuestionDef, type QuestionKind,
  type QuestionScope,
} from '../../supabase/functions/_shared/questions.ts';
import {
  archiveEventQuestion, draftProblems, EMPTY_DRAFT, listEventQuestions, reorderEventQuestions, saveEventQuestion,
  type AdminQuestion, type AnswerDraft,
} from '../lib/checkoutQuestions';
import CheckoutQuestionsForm from './CheckoutQuestionsForm';

const KIND_LABEL: Record<QuestionKind, string> = {
  text: 'Short text', long_text: 'Long text', single_choice: 'One choice', multiple_choice: 'Several choices',
  checkbox: 'Checkbox (I agree)', number: 'Number', date: 'Date', phone: 'Phone number', email: 'Email',
};

interface Draft {
  id?: string;
  label: string;
  help_text: string;
  kind: QuestionKind;
  optionsText: string;
  required: boolean;
  scope: QuestionScope;
  tier_ids: string[];
  max_length: string;
  min_choices: string;
  max_choices: string;
  min_value: string;
  max_value: string;
  hidden: boolean;
  hasAnswers: boolean;
  /** "Show only if": the question it depends on ('' = always asked) and the answers that show it. */
  parent_question_id: string;
  parent_values: string[];
}

const BLANK: Draft = {
  label: '', help_text: '', kind: 'text', optionsText: '', required: false, scope: 'order', tier_ids: [],
  max_length: '', min_choices: '', max_choices: '', min_value: '', max_value: '', hidden: false, hasAnswers: false,
  parent_question_id: '', parent_values: [],
};

const inputCls =
  'w-full bg-slate-50 border-2 border-transparent rounded-2xl py-3 px-5 text-slate-900 font-bold ' +
  'focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary focus:bg-white transition-all shadow-inner';
const smallLabel = 'text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1';

const num = (s: string): number | null => (s.trim() === '' || !Number.isFinite(Number(s)) ? null : Number(s));
const int = (s: string): number | null => (s.trim() === '' || !Number.isInteger(Number(s)) ? null : Number(s));

/** The draft as the RPC body (only the limits its kind uses). */
export function draftToQuestion(d: Draft): Partial<QuestionDef> & { hidden: boolean } {
  const choice = CHOICE_KINDS.includes(d.kind);
  return {
    label: d.label.trim(),
    help_text: d.help_text.trim() || null,
    kind: d.kind,
    options: choice ? d.optionsText.split('\n').map((o) => o.trim()).filter(Boolean) : [],
    required: d.required,
    scope: d.scope,
    tier_ids: d.tier_ids.length > 0 ? d.tier_ids : null,
    max_length: d.kind === 'text' || d.kind === 'long_text' ? int(d.max_length) : null,
    min_choices: d.kind === 'multiple_choice' ? int(d.min_choices) : null,
    max_choices: d.kind === 'multiple_choice' ? int(d.max_choices) : null,
    min_value: d.kind === 'number' ? num(d.min_value) : null,
    max_value: d.kind === 'number' ? num(d.max_value) : null,
    hidden: d.hidden,
    parent_question_id: d.parent_question_id || null,
    parent_values: d.parent_question_id ? d.parent_values : null,
  };
}

/** "only if Size is L or XL" / "only if Photos ok? is ticked". */
export function conditionText(q: Pick<QuestionDef, 'parent_question_id' | 'parent_values'>, all: readonly QuestionDef[]): string | null {
  if (!q.parent_question_id) return null;
  const p = all.find((x) => x.id === q.parent_question_id);
  if (!p) return 'only if (a question no longer asked)';
  if (p.kind === 'checkbox') return `only if "${p.label}" is ticked`;
  return `only if "${p.label}" is ${(q.parent_values ?? []).join(' or ')}`;
}

function toDraft(q: AdminQuestion): Draft {
  const s = (v: number | null | undefined) => (v == null ? '' : String(v));
  return {
    id: q.id, label: q.label, help_text: q.help_text ?? '', kind: q.kind, optionsText: (q.options ?? []).join('\n'),
    required: q.required, scope: q.scope, tier_ids: q.tier_ids ?? [], max_length: s(q.max_length),
    min_choices: s(q.min_choices), max_choices: s(q.max_choices), min_value: s(q.min_value), max_value: s(q.max_value),
    hidden: q.hidden, hasAnswers: q.answer_count > 0,
    parent_question_id: q.parent_question_id ?? '', parent_values: q.parent_values ?? [],
  };
}

export default function QuestionBuilder({ eventId, tiers }: { eventId: string; tiers: { id: string; name: string }[] }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<AdminQuestion[]>([]);
  const [loading, setLoading] = useState(true);
  const [unavailable, setUnavailable] = useState(false);
  const [draft, setDraft] = useState<Draft>({ ...BLANK });
  const [saving, setSaving] = useState(false);
  const [showArchived, setShowArchived] = useState(false);
  const [preview, setPreview] = useState<AnswerDraft>(EMPTY_DRAFT);
  const [previewTier, setPreviewTier] = useState<string>('');

  const reload = async () => {
    try {
      setRows(await listEventQuestions(eventId));
      setUnavailable(false);
    } catch (e) {
      console.error('listEventQuestions failed:', e);
      setUnavailable(true);
    } finally {
      setLoading(false);
    }
  };
  useEffect(() => { void reload(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [eventId]);

  const active = rows.filter((r) => !r.archived);
  const archived = rows.filter((r) => r.archived);
  const tierName = (id: string) => tiers.find((t) => t.id === id)?.name ?? 'a removed ticket type';
  const problem = questionDefProblem(draftToQuestion(draft))
    ?? conditionProblem({ ...draftToQuestion(draft), id: draft.id }, active);
  // Questions this one may depend on: active choice / checkbox questions, not itself;
  // a per-order question only on per-order ones.
  const parentChoices = active.filter((q) => q.id !== draft.id && CONDITION_PARENT_KINDS.includes(q.kind)
    && (draft.scope === 'ticket' || q.scope === 'order'));
  const parent = active.find((q) => q.id === draft.parent_question_id);
  const previewTierId = previewTier || tiers[0]?.id || '';
  const previewQs = active.filter((q) => !q.hidden);
  const previewTiers = previewTierId ? [previewTierId, previewTierId] : [];

  const save = async () => {
    if (problem) { toast({ kind: 'error', message: problem }); return; }
    setSaving(true);
    try {
      await saveEventQuestion(eventId, draftToQuestion(draft), draft.id);
      setDraft({ ...BLANK });
      await reload();
      toast({ kind: 'success', message: draft.id ? 'Question updated.' : 'Question added.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Could not save the question.' });
    } finally {
      setSaving(false);
    }
  };

  const act = async (fn: () => Promise<unknown>, ok: string) => {
    try {
      await fn();
      await reload();
      toast({ kind: 'success', message: ok });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Something went wrong.' });
    }
  };

  const move = (i: number, dir: -1 | 1) => {
    const ids = active.map((q) => q.id);
    const j = i + dir;
    if (j < 0 || j >= ids.length) return;
    [ids[i], ids[j]] = [ids[j], ids[i]];
    void act(() => reorderEventQuestions(eventId, ids), 'Order saved.');
  };

  if (loading || unavailable) return null;

  return (
    <section className="bg-white p-10 rounded-[3rem] border border-slate-100 shadow-xl space-y-6" aria-labelledby="qb-title" data-testid="question-builder">
      <div className="flex items-center space-x-3 mb-2">
        <HelpCircle className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 id="qb-title" className="text-xs font-bold text-slate-400 uppercase tracking-widest leading-none">Checkout questions</h2>
      </div>
      <p className="text-slate-400 text-xs font-bold -mt-2">
        Ask buyers before they pay: T-shirt size, dietary needs, company name, a policy to agree to. Per order or per ticket,
        for every ticket type or only some. Answers show in the event report, the attendee export and at the door.
      </p>

      {active.length > 0 && (
        <ol className="space-y-2">
          {active.map((q, i) => (
            <li key={q.id} className="flex items-center justify-between bg-slate-50 rounded-2xl px-5 py-3 gap-3">
              <div className="min-w-0">
                <p className="font-bold text-slate-900 text-sm truncate">
                  {q.label}{q.required && <span className="text-rose-600" aria-label="required"> *</span>}
                </p>
                <p className="text-slate-400 text-xs font-bold">
                  {KIND_LABEL[q.kind]} · {q.scope === 'ticket' ? 'each ticket' : 'once per order'}
                  {q.tier_ids && q.tier_ids.length > 0 ? ` · only ${q.tier_ids.map(tierName).join(', ')}` : ''}
                  {q.hidden ? ' · hidden (door only)' : ''}
                  {q.parent_question_id ? ` · ${conditionText(q, active)}` : ''}
                  {q.answer_count > 0 ? ` · ${q.answer_count} answer${q.answer_count === 1 ? '' : 's'}` : ''}
                </p>
              </div>
              <div className="flex items-center gap-1 shrink-0">
                <button type="button" onClick={() => move(i, -1)} disabled={i === 0} aria-label={`Move ${q.label} up`}
                  className="p-1.5 text-slate-400 hover:text-slate-900 disabled:opacity-30"><ArrowUp className="w-4 h-4" /></button>
                <button type="button" onClick={() => move(i, 1)} disabled={i === active.length - 1} aria-label={`Move ${q.label} down`}
                  className="p-1.5 text-slate-400 hover:text-slate-900 disabled:opacity-30"><ArrowDown className="w-4 h-4" /></button>
                <button type="button" onClick={() => void act(() => saveEventQuestion(eventId, { hidden: !q.hidden }, q.id), q.hidden ? 'Asked at checkout again.' : 'Hidden from checkout.')}
                  aria-label={q.hidden ? `Ask ${q.label} at checkout` : `Hide ${q.label} from checkout`}
                  className="p-1.5 text-slate-400 hover:text-slate-900">{q.hidden ? <Eye className="w-4 h-4" /> : <EyeOff className="w-4 h-4" />}</button>
                <button type="button" onClick={() => setDraft(toDraft(q))} aria-label={`Edit ${q.label}`}
                  className="p-1.5 text-slate-400 hover:text-slate-900"><Pencil className="w-4 h-4" /></button>
                <button type="button" onClick={() => void act(() => archiveEventQuestion(q.id), 'Archived. Its answers are kept.')}
                  aria-label={`Archive ${q.label}`} className="p-1.5 text-slate-300 hover:text-red-500"><Archive className="w-4 h-4" /></button>
              </div>
            </li>
          ))}
        </ol>
      )}

      {archived.length > 0 && (
        <div>
          <button type="button" onClick={() => setShowArchived((v) => !v)} className="text-xs font-bold text-slate-400 underline">
            {showArchived ? 'Hide' : 'Show'} {archived.length} archived question{archived.length === 1 ? '' : 's'}
          </button>
          {showArchived && (
            <ul className="mt-2 space-y-1">
              {archived.map((q) => (
                <li key={q.id} className="flex items-center justify-between text-xs text-slate-500 px-5">
                  <span>{q.label} · {q.answer_count} answer{q.answer_count === 1 ? '' : 's'} kept</span>
                  <button type="button" onClick={() => void act(() => archiveEventQuestion(q.id, false), 'Restored.')}
                    className="inline-flex items-center gap-1 font-bold text-slate-600 hover:text-slate-900">
                    <RotateCcw className="w-3 h-3" aria-hidden="true" /> Restore
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      {/* The add / edit form */}
      <div className="grid grid-cols-2 gap-4 border-t border-slate-100 pt-6">
        <p className="col-span-2 text-xs font-black text-slate-500 uppercase tracking-widest">{draft.id ? 'Edit question' : 'Add a question'}</p>
        <label className="col-span-2 space-y-1">
          <span className={smallLabel}>Question</span>
          <input value={draft.label} maxLength={200} onChange={(e) => setDraft({ ...draft, label: e.target.value })}
            placeholder="e.g. T-shirt size" className={inputCls} />
        </label>
        <label className="col-span-2 space-y-1">
          <span className={smallLabel}>Help text (optional)</span>
          <input value={draft.help_text} maxLength={500} onChange={(e) => setDraft({ ...draft, help_text: e.target.value })}
            placeholder="A line under the question" className={inputCls} />
        </label>
        <label className="space-y-1">
          <span className={smallLabel}>Type</span>
          <select value={draft.kind} disabled={draft.hasAnswers} onChange={(e) => setDraft({ ...draft, kind: e.target.value as QuestionKind })} className={inputCls}>
            {QUESTION_KINDS.map((k) => <option key={k} value={k}>{KIND_LABEL[k]}</option>)}
          </select>
        </label>
        <label className="space-y-1">
          <span className={smallLabel}>Asked</span>
          <select value={draft.scope} disabled={draft.hasAnswers} onChange={(e) => setDraft({ ...draft, scope: e.target.value as QuestionScope })} className={inputCls}>
            <option value="order">Once per order</option>
            <option value="ticket">For each ticket</option>
          </select>
        </label>
        {draft.hasAnswers && (
          <p className="col-span-2 text-[11px] text-slate-400">This question has answers: its type and how it is asked stay as they are (archive it and add a new one to change them). Renaming keeps the old answers with the old wording.</p>
        )}
        {CHOICE_KINDS.includes(draft.kind) && (
          <label className="col-span-2 space-y-1">
            <span className={smallLabel}>Options, one per line (2 to 50)</span>
            <textarea rows={4} value={draft.optionsText} onChange={(e) => setDraft({ ...draft, optionsText: e.target.value })}
              placeholder={'S\nM\nL\nXL'} className={inputCls} />
          </label>
        )}
        {(draft.kind === 'text' || draft.kind === 'long_text') && (
          <label className="space-y-1">
            <span className={smallLabel}>Max length (optional)</span>
            <input type="number" min={1} value={draft.max_length} onChange={(e) => setDraft({ ...draft, max_length: e.target.value })} className={inputCls} />
          </label>
        )}
        {draft.kind === 'multiple_choice' && (<>
          <label className="space-y-1">
            <span className={smallLabel}>At least (optional)</span>
            <input type="number" min={0} value={draft.min_choices} onChange={(e) => setDraft({ ...draft, min_choices: e.target.value })} className={inputCls} />
          </label>
          <label className="space-y-1">
            <span className={smallLabel}>At most (optional)</span>
            <input type="number" min={1} value={draft.max_choices} onChange={(e) => setDraft({ ...draft, max_choices: e.target.value })} className={inputCls} />
          </label>
        </>)}
        {draft.kind === 'number' && (<>
          <label className="space-y-1">
            <span className={smallLabel}>Smallest (optional)</span>
            <input type="number" value={draft.min_value} onChange={(e) => setDraft({ ...draft, min_value: e.target.value })} className={inputCls} />
          </label>
          <label className="space-y-1">
            <span className={smallLabel}>Largest (optional)</span>
            <input type="number" value={draft.max_value} onChange={(e) => setDraft({ ...draft, max_value: e.target.value })} className={inputCls} />
          </label>
        </>)}
        {tiers.length > 1 && (
          <fieldset className="col-span-2">
            <legend className={smallLabel}>Ask for these ticket types (none ticked = all)</legend>
            <div className="flex flex-wrap gap-x-4 mt-1">
              {tiers.map((t) => (
                <label key={t.id} className="flex items-center gap-2 text-sm text-slate-700">
                  <input type="checkbox" checked={draft.tier_ids.includes(t.id)}
                    onChange={(e) => setDraft({ ...draft, tier_ids: e.target.checked ? [...draft.tier_ids, t.id] : draft.tier_ids.filter((x) => x !== t.id) })} />
                  {t.name}
                </label>
              ))}
            </div>
          </fieldset>
        )}
        {parentChoices.length > 0 && (
          <fieldset className="col-span-2 space-y-2" data-testid="question-condition">
            <legend className={smallLabel}>Show only if…</legend>
            <select aria-label="Show only if this question" value={draft.parent_question_id}
              onChange={(e) => {
                const next = active.find((q) => q.id === e.target.value);
                setDraft({ ...draft, parent_question_id: e.target.value, parent_values: next?.kind === 'checkbox' ? ['true'] : [] });
              }} className={inputCls}>
              <option value="">Always ask it</option>
              {parentChoices.map((q) => <option key={q.id} value={q.id}>{q.label}</option>)}
            </select>
            {parent && parent.kind === 'checkbox' && (
              <p className="text-xs text-slate-500 ml-1">Asked when “{parent.label}” is ticked.</p>
            )}
            {parent && parent.kind !== 'checkbox' && (
              <div className="flex flex-wrap gap-x-4 ml-1" role="group" aria-label={`Answers of ${parent.label} that show it`}>
                {(parent.options ?? []).map((o) => (
                  <label key={o} className="flex items-center gap-2 text-sm text-slate-700">
                    <input type="checkbox" checked={draft.parent_values.includes(o)}
                      onChange={(e) => setDraft({ ...draft, parent_values: e.target.checked ? [...draft.parent_values, o] : draft.parent_values.filter((x) => x !== o) })} />
                    {o}
                  </label>
                ))}
              </div>
            )}
            {parent && <p className="text-[11px] text-slate-400 ml-1">Hidden from buyers until then; a hidden question is never required and its answer isn't kept.</p>}
          </fieldset>
        )}
        <label className="flex items-center gap-2 text-sm font-bold text-slate-700">
          <input type="checkbox" checked={draft.required} onChange={(e) => setDraft({ ...draft, required: e.target.checked })} />
          Required{draft.kind === 'checkbox' ? ' (must be ticked)' : ''}
        </label>
        <label className="flex items-center gap-2 text-sm font-bold text-slate-700">
          <input type="checkbox" checked={draft.hidden} onChange={(e) => setDraft({ ...draft, hidden: e.target.checked })} />
          Hidden (door staff fill it)
        </label>
        {problem && draft.label.trim() !== '' && <p className="col-span-2 text-xs text-rose-600" role="status">{problem}</p>}
      </div>
      <div className="flex gap-3">
        <button type="button" disabled={saving || !!problem} onClick={save}
          className="flex-1 flex items-center justify-center space-x-2 bg-slate-900 hover:bg-slate-800 text-white py-3 rounded-2xl font-black uppercase italic tracking-tighter text-xs transition-all disabled:opacity-50">
          <Plus className="w-4 h-4" aria-hidden="true" />
          <span>{saving ? 'Saving…' : draft.id ? 'Save question' : 'Add question'}</span>
        </button>
        {draft.id && (
          <button type="button" onClick={() => setDraft({ ...BLANK })} className="px-5 py-3 rounded-2xl border border-slate-200 text-xs font-bold text-slate-600">
            Cancel
          </button>
        )}
      </div>

      {previewQs.length > 0 && previewTierId && (
        <div className="border-t border-slate-100 pt-6">
          <div className="flex items-center justify-between mb-3">
            <p className="text-xs font-black text-slate-500 uppercase tracking-widest">Preview: an order of 2 tickets</p>
            {tiers.length > 1 && (
              <select aria-label="Preview as ticket type" value={previewTierId} onChange={(e) => setPreviewTier(e.target.value)}
                className="text-xs border border-slate-200 rounded-lg px-2 py-1">
                {tiers.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
            )}
          </div>
          <CheckoutQuestionsForm questions={previewQs} ticketTiers={previewTiers} value={preview} onChange={setPreview}
            problems={draftProblems(previewQs, previewTiers, preview)} showErrors tone="light" />
        </div>
      )}
    </section>
  );
}
