// The checkout questions step (mig 20261106110000, docs/checkout-questions.md):
// the organizer's questions, once per order and once per ticket, before the
// buyer pays or claims. Plain form fields on our own page (no scripts, nothing
// near a card field: docs/pci.md). The answers live in the parent's state and
// ride in the checkout request itself, never only in storage (in-app browsers
// have none).
//
// "Show only if" questions (mig 20261107110000) appear once their parent has
// an answer that shows them, and disappear (their answer left out of the
// request) when it changes; the server applies the same rule.
//
// Accessibility: every field has a <label> (radio and checkbox groups a
// <fieldset>/<legend>), required ones say so (aria-required + a visible
// marker), and a problem shows under its field (role="alert",
// aria-invalid, aria-describedby) once the buyer has tried to continue.

import { useId } from 'react';
import {
  maxLengthFor, problemText, visibleQuestionsFor, type AnswerProblem, type QuestionDef,
} from '../../supabase/functions/_shared/questions.ts';
import type { AnswerDraft, RawAnswer } from '../lib/checkoutQuestions';

interface Props {
  questions: readonly QuestionDef[];
  /** The ticket type of each ticket of the order (lib/checkoutQuestions ticketTiersFor). */
  ticketTiers: readonly string[];
  value: AnswerDraft;
  onChange: (next: AnswerDraft) => void;
  /** draftProblems(): keyed "order:<id>" / "<ticket>:<id>". */
  problems: Record<string, AnswerProblem>;
  /** Show problems (after the buyer tried to continue). */
  showErrors: boolean;
  /** Names on the tickets, if the page asks for them (headings only). */
  ticketNames?: string[];
  tone?: 'dark' | 'light';
}

const RADIO_MAX = 5;

export default function CheckoutQuestionsForm({ questions, ticketTiers, value, onChange, problems, showErrors, ticketNames, tone = 'dark' }: Props) {
  const base = useId().replace(/:/g, '');
  const f = visibleQuestionsFor(questions, ticketTiers, value);
  if (f.order.length === 0 && f.ticket.every((t) => t.length === 0)) return null;
  const dark = tone === 'dark';
  const cls = {
    box: dark ? 'mb-8' : 'mb-6',
    heading: dark ? 'type text-[11px] text-white/60 uppercase tracking-widest mb-3' : 'text-xs font-bold text-slate-500 uppercase tracking-widest mb-3',
    label: dark ? 'type block text-[12px] text-white/85 mb-1.5' : 'block text-sm font-semibold text-slate-800 mb-1.5',
    help: dark ? 'type block text-[11px] text-white/50 mb-1.5' : 'block text-xs text-slate-500 mb-1.5',
    input: dark
      ? 'type w-full bg-black border border-white/10 px-3 py-2.5 text-white text-sm placeholder-white/25 focus:border-brand-primary outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60'
      : 'w-full bg-white border border-slate-300 rounded-lg px-3 py-2.5 text-slate-900 text-sm focus:border-brand-primary outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60',
    bad: dark ? 'border-brand-accent' : 'border-rose-500',
    error: dark ? 'type text-[11px] text-brand-accent mt-1' : 'text-xs text-rose-600 mt-1',
    option: dark ? 'type flex items-center gap-2 text-sm text-white/85 py-1' : 'flex items-center gap-2 text-sm text-slate-800 py-1',
    star: dark ? 'text-brand-accent' : 'text-rose-600',
    ticketBox: dark ? 'border border-white/10 p-4 space-y-4' : 'border border-slate-200 rounded-xl p-4 space-y-4',
    ticketTitle: dark ? 'type text-[11px] text-white/70 uppercase tracking-widest' : 'text-xs font-bold text-slate-600 uppercase tracking-widest',
  };

  const get = (ticket: number | null, id: string): RawAnswer =>
    ticket === null ? value.order[id] : value.tickets[ticket - 1]?.[id];
  const set = (ticket: number | null, id: string, v: RawAnswer) => {
    if (ticket === null) {
      onChange({ ...value, order: { ...value.order, [id]: v } });
      return;
    }
    const tickets = [...value.tickets];
    while (tickets.length < ticket) tickets.push({});
    tickets[ticket - 1] = { ...tickets[ticket - 1], [id]: v };
    onChange({ ...value, tickets });
  };

  const field = (q: QuestionDef, ticket: number | null) => {
    const id = `${base}-${ticket ?? 'o'}-${q.id.slice(0, 8)}`;
    const problem = showErrors ? problems[`${ticket ?? 'order'}:${q.id}`] : undefined;
    const errId = `${id}-err`;
    const helpId = `${id}-help`;
    const describedBy = [q.help_text ? helpId : null, problem ? errId : null].filter(Boolean).join(' ') || undefined;
    const v = get(ticket, q.id);
    const star = q.required ? <span className={cls.star} aria-hidden="true"> *</span> : null;
    const help = q.help_text ? <span id={helpId} className={cls.help}>{q.help_text}</span> : null;
    const err = problem ? <p id={errId} role="alert" className={cls.error}>{problemText(problem, q)}</p> : null;
    const inputCls = `${cls.input} ${problem ? cls.bad : ''}`;
    const common = {
      id, 'aria-required': q.required || undefined, 'aria-invalid': problem ? true : undefined, 'aria-describedby': describedBy,
    } as const;

    if (q.kind === 'checkbox') {
      return (
        <div key={id}>
          <label htmlFor={id} className={cls.option}>
            <input type="checkbox" {...common} checked={v === true} onChange={(e) => set(ticket, q.id, e.target.checked)}
              className="w-4 h-4 accent-brand-primary" />
            <span>{q.label}{star}</span>
          </label>
          {help}{err}
        </div>
      );
    }
    if (q.kind === 'single_choice' && (q.options ?? []).length <= RADIO_MAX) {
      return (
        <fieldset key={id} aria-describedby={describedBy} aria-invalid={problem ? true : undefined}>
          <legend className={cls.label}>{q.label}{star}</legend>
          {help}
          <div role="radiogroup" aria-required={q.required || undefined} className="flex flex-wrap gap-x-4">
            {(q.options ?? []).map((o, i) => (
              <label key={o} htmlFor={`${id}-${i}`} className={cls.option}>
                <input type="radio" id={`${id}-${i}`} name={id} value={o} checked={v === o}
                  onChange={() => set(ticket, q.id, o)} className="w-4 h-4 accent-brand-primary" />
                <span>{o}</span>
              </label>
            ))}
          </div>
          {err}
        </fieldset>
      );
    }
    if (q.kind === 'multiple_choice') {
      const picked = Array.isArray(v) ? v : [];
      return (
        <fieldset key={id} aria-describedby={describedBy} aria-invalid={problem ? true : undefined}>
          <legend className={cls.label}>{q.label}{star}</legend>
          {help}
          <div className="flex flex-wrap gap-x-4">
            {(q.options ?? []).map((o, i) => (
              <label key={o} htmlFor={`${id}-${i}`} className={cls.option}>
                <input type="checkbox" id={`${id}-${i}`} checked={picked.includes(o)}
                  onChange={(e) => set(ticket, q.id, e.target.checked ? [...picked, o] : picked.filter((x) => x !== o))}
                  className="w-4 h-4 accent-brand-primary" />
                <span>{o}</span>
              </label>
            ))}
          </div>
          {err}
        </fieldset>
      );
    }
    const label = <label htmlFor={id} className={cls.label}>{q.label}{star}</label>;
    const text = typeof v === 'string' || typeof v === 'number' ? String(v) : '';
    let control;
    if (q.kind === 'single_choice') {
      control = (
        <select {...common} value={text} onChange={(e) => set(ticket, q.id, e.target.value)} className={inputCls}>
          <option value="">Choose…</option>
          {(q.options ?? []).map((o) => <option key={o} value={o}>{o}</option>)}
        </select>
      );
    } else if (q.kind === 'long_text') {
      control = (
        <textarea {...common} rows={3} maxLength={maxLengthFor(q)} value={text}
          onChange={(e) => set(ticket, q.id, e.target.value)} className={inputCls} />
      );
    } else {
      const type = q.kind === 'number' ? 'number' : q.kind === 'date' ? 'date' : q.kind === 'phone' ? 'tel' : q.kind === 'email' ? 'email' : 'text';
      control = (
        <input {...common} type={type} value={text}
          maxLength={q.kind === 'text' ? maxLengthFor(q) : undefined}
          min={q.kind === 'number' && q.min_value != null ? q.min_value : undefined}
          max={q.kind === 'number' && q.max_value != null ? q.max_value : undefined}
          inputMode={q.kind === 'number' ? 'decimal' : q.kind === 'phone' ? 'tel' : undefined}
          autoComplete={q.kind === 'email' ? 'email' : q.kind === 'phone' ? 'tel' : undefined}
          onChange={(e) => set(ticket, q.id, e.target.value)} className={inputCls} />
      );
    }
    return <div key={id}>{label}{help}{control}{err}</div>;
  };

  return (
    <section className={cls.box} aria-labelledby={`${base}-title`} data-testid="checkout-questions">
      <h3 id={`${base}-title`} className={cls.heading}>
        A few questions from the organizer
      </h3>
      {f.order.length > 0 && <div className="space-y-4 mb-4">{f.order.map((q) => field(q, null))}</div>}
      {f.ticket.some((t) => t.length > 0) && (
        <div className="space-y-3">
          {f.ticket.map((list, i) => list.length === 0 ? null : (
            <div key={i} className={cls.ticketBox} role="group" aria-label={`Ticket ${i + 1}`}>
              <p className={cls.ticketTitle}>
                Ticket {i + 1}{ticketNames?.[i]?.trim() ? ` · ${ticketNames[i].trim()}` : ''}
              </p>
              {list.map((q) => field(q, i + 1))}
            </div>
          ))}
        </div>
      )}
      <p className={dark ? 'type text-[10px] text-white/40 mt-3' : 'text-[11px] text-slate-400 mt-3'}>
        <span aria-hidden="true">*</span> required. The organizer sees your answers.
      </p>
    </section>
  );
}
