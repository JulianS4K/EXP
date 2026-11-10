// "Fair / multi-day setup" in the event editor (mig 20261113110000). A preset
// generator: a few answers (the days and their gate hours, prices, re-entry,
// parking and camping) become ordinary ticket types, check-in lists and
// add-ons in one transaction (exos_fair_setup), which the organizer edits
// afterwards in the usual places. Pure logic and the parking / camping
// rationale: lib/fairSetup.ts. Saves on its own button, not the event form.

import { useMemo, useState } from 'react';
import { CalendarRange, Plus, Trash2 } from 'lucide-react';
import {
  MAX_FAIR_DAYS, buildFairPlan, dayLabel, defaultFairInput, fairSetupErrors, nextDate, planSummary,
  type FairDayInput, type FairSetupInput, type ReentryPreset,
} from '../lib/fairSetup';
import { runFairSetup, type FairSetupResult } from '../lib/fairSetupApi';
import { formatInTz, getBrowserTimezone, utcToZonedWallClock } from '../lib/datetime';
import { useToast } from '../context/ToastContext';

interface ProductForm { enabled: boolean; price: string; capacity: string }
interface Form {
  days: FairDayInput[];
  reentry: ReentryPreset;
  dayPass: { price: string; capacity: string };
  multi: ProductForm & { days: string };
  any: ProductForm;
  parking: ProductForm;
  camping: ProductForm;
}

const inputCls =
  'w-full bg-black border border-white/20 py-3 px-4 font-bold text-white focus:outline-none ' +
  'focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary transition-colors';
const legendCls = 'type text-[10px] text-white/70 uppercase tracking-widest mb-1';
const labelCls = 'type text-[10px] text-white/70 uppercase tracking-widest';

const dollars = (cents: number) => (cents / 100).toFixed(2);
/** "15" / "15.5" / "$15.50" → 1550; anything else NaN (the errors say so). */
const toCents = (v: string) => {
  const t = v.trim().replace(/^\$/, '');
  return /^\d+(\.\d{1,2})?$/.test(t) ? Math.round(Number(t) * 100) : NaN;
};
const toInt = (v: string) => (/^\d+$/.test(v.trim()) ? Number(v.trim()) : NaN);

function formFrom(input: FairSetupInput): Form {
  const p = (x: { enabled: boolean; priceCents: number; capacity: number }): ProductForm =>
    ({ enabled: x.enabled, price: dollars(x.priceCents), capacity: String(x.capacity) });
  return {
    days: input.days,
    reentry: input.reentry,
    dayPass: { price: dollars(input.dayPass.priceCents), capacity: String(input.dayPass.capacity) },
    multi: { ...p(input.multiDay), days: '' },
    any: p(input.anyDay),
    parking: p(input.parking),
    camping: p(input.camping),
  };
}

function inputFrom(f: Form, timezone: string): FairSetupInput {
  const p = (x: ProductForm) => ({ enabled: x.enabled, priceCents: toCents(x.price), capacity: toInt(x.capacity) });
  return {
    timezone,
    days: f.days,
    reentry: f.reentry,
    dayPass: { priceCents: toCents(f.dayPass.price), capacity: toInt(f.dayPass.capacity) },
    multiDay: { ...p(f.multi), days: f.multi.days ? toInt(f.multi.days) : null },
    anyDay: p(f.any),
    parking: p(f.parking),
    camping: p(f.camping),
  };
}

export default function FairSetupPanel({
  eventId, timezone, startsAt, onCreated,
}: {
  eventId: string;
  timezone?: string;
  startsAt?: Date | null;
  onCreated?: (r: FairSetupResult) => void;
}) {
  const { toast } = useToast();
  const tz = timezone || getBrowserTimezone();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [form, setForm] = useState<Form>(() =>
    formFrom(defaultFairInput(startsAt ? utcToZonedWallClock(startsAt, tz).slice(0, 10) : null, tz)));

  const input = useMemo(() => inputFrom(form, tz), [form, tz]);
  const errors = useMemo(() => fairSetupErrors(input), [input]);
  const plan = useMemo(() => (errors.length ? null : buildFairPlan(input)), [errors, input]);

  const setDay = (i: number, patch: Partial<FairDayInput>) =>
    setForm({ ...form, days: form.days.map((d, j) => (j === i ? { ...d, ...patch } : d)) });
  const addDay = () => {
    const last = form.days[form.days.length - 1];
    const date = last && /^\d{4}-\d{2}-\d{2}$/.test(last.date) ? nextDate(last.date) : '';
    setForm({ ...form, days: [...form.days, { date, opens: last?.opens ?? '09:00', closes: last?.closes ?? '22:00' }] });
  };
  const product = (key: 'any' | 'parking' | 'camping', patch: Partial<ProductForm>) =>
    setForm({ ...form, [key]: { ...form[key], ...patch } });

  const create = async () => {
    if (!plan) return;
    setBusy(true);
    try {
      const r = await runFairSetup(eventId, plan);
      const ends = r.endsAt ? ` The event now ends ${formatInTz(new Date(r.endsAt), tz)}.` : '';
      setDone(`Created ${plan.tiers.length} ticket types, ${plan.lists.length} check-in lists and ${plan.addons.length} add-ons.${ends}`);
      toast({ kind: 'success', message: 'Fair set up.' });
      onCreated?.(r);
    } catch (e) {
      toast({ kind: 'error', message: e instanceof Error ? e.message : 'Could not set up the fair.' });
    } finally {
      setBusy(false);
    }
  };

  const productFields = (key: 'any' | 'parking' | 'camping', title: string, help: string, unit: string) => (
    <fieldset className="border border-white/10 p-3 space-y-2">
      <legend className={legendCls}>{title}</legend>
      <label className="flex items-center gap-2 text-sm text-white">
        <input type="checkbox" checked={form[key].enabled} onChange={(e) => product(key, { enabled: e.target.checked })} />
        {help}
      </label>
      {form[key].enabled && (
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1">
            <label htmlFor={`fair-${key}-price`} className={labelCls}>Price ($)</label>
            <input id={`fair-${key}-price`} inputMode="decimal" value={form[key].price}
              onChange={(e) => product(key, { price: e.target.value })} className={inputCls} />
          </div>
          <div className="space-y-1">
            <label htmlFor={`fair-${key}-cap`} className={labelCls}>{unit}</label>
            <input id={`fair-${key}-cap`} inputMode="numeric" value={form[key].capacity}
              onChange={(e) => product(key, { capacity: e.target.value })} className={inputCls} />
          </div>
        </div>
      )}
    </fieldset>
  );

  return (
    <section className="border border-white/10 p-4 space-y-4" data-testid="fair-setup" aria-labelledby="fair-setup-title">
      <div className="flex items-start gap-3">
        <CalendarRange className="w-5 h-5 text-brand-primary shrink-0 mt-0.5" aria-hidden="true" />
        <div>
          <h3 id="fair-setup-title" className="type text-[11px] text-white uppercase tracking-widest font-black">
            Fair / multi-day setup
          </h3>
          <p className="text-sm text-white/70 mt-1">
            For fairs, rodeos and festivals: makes a day pass for each day, a multi-day pass, an any-day pass, a
            check-in list per day, and parking and camping with their own codes on a lot list. You can edit all of it
            afterwards.
          </p>
        </div>
      </div>

      {done ? (
        <div role="status" data-testid="fair-setup-done" className="border border-brand-primary/50 p-3 text-sm text-white space-y-2">
          <p>{done}</p>
          <p className="text-white/70">
            Edit them in the usual places: ticket types under Ticket tiers, the day and lot lists under Check-in lists,
            parking and camping under Add-ons.
          </p>
        </div>
      ) : !open ? (
        <button type="button" onClick={() => setOpen(true)}
          className="flex items-center gap-2 px-4 py-3 border border-white/20 text-white text-[11px] font-black uppercase tracking-widest hover:border-brand-primary">
          <Plus className="w-4 h-4" aria-hidden="true" /> Set up a fair or multi-day event
        </button>
      ) : (
        <div className="space-y-4">
          <fieldset className="space-y-2">
            <legend className={legendCls}>Days and gate hours ({tz})</legend>
            <ul className="space-y-2">
              {form.days.map((d, i) => (
                <li key={i} className="grid grid-cols-[1fr_auto_auto_auto] gap-2 items-end">
                  <div className="space-y-1">
                    <label htmlFor={`fair-day-${i}`} className={labelCls}>Day {i + 1}</label>
                    <input id={`fair-day-${i}`} type="date" value={d.date} onChange={(e) => setDay(i, { date: e.target.value })} className={inputCls} />
                  </div>
                  <div className="space-y-1">
                    <label htmlFor={`fair-open-${i}`} className={labelCls}>Gates open</label>
                    <input id={`fair-open-${i}`} type="time" value={d.opens} onChange={(e) => setDay(i, { opens: e.target.value })} className={inputCls} />
                  </div>
                  <div className="space-y-1">
                    <label htmlFor={`fair-close-${i}`} className={labelCls}>Close</label>
                    <input id={`fair-close-${i}`} type="time" value={d.closes} onChange={(e) => setDay(i, { closes: e.target.value })} className={inputCls} />
                  </div>
                  <button type="button" disabled={form.days.length <= 1}
                    onClick={() => setForm({ ...form, days: form.days.filter((_, j) => j !== i) })}
                    className="p-3 text-white/70 hover:text-red-400 disabled:opacity-40"
                    aria-label={`Remove day ${i + 1}${/^\d{4}-\d{2}-\d{2}$/.test(d.date) ? ` (${dayLabel(d.date)})` : ''}`}>
                    <Trash2 className="w-4 h-4" aria-hidden="true" />
                  </button>
                </li>
              ))}
            </ul>
            {form.days.length < MAX_FAIR_DAYS && (
              <button type="button" onClick={addDay}
                className="flex items-center gap-2 px-3 py-2 border border-white/20 text-white text-[11px] font-black uppercase tracking-widest">
                <Plus className="w-4 h-4" aria-hidden="true" /> Add a day
              </button>
            )}
            <p className="text-xs text-white/70">A closing time at or before opening means after midnight.</p>
          </fieldset>

          <fieldset className="space-y-2">
            <legend className={legendCls}>Re-entry</legend>
            <label className="flex items-start gap-2 text-sm text-white">
              <input type="radio" name="fair-reentry" className="mt-1" checked={form.reentry === 'same-day'}
                onChange={() => setForm({ ...form, reentry: 'same-day' })} />
              <span>Same-day re-entry: gate staff scan people out and back in, the same day only.</span>
            </label>
            <label className="flex items-start gap-2 text-sm text-white">
              <input type="radio" name="fair-reentry" className="mt-1" checked={form.reentry === 'none'}
                onChange={() => setForm({ ...form, reentry: 'none' })} />
              <span>No re-entry: one entry a day.</span>
            </label>
          </fieldset>

          <fieldset className="border border-white/10 p-3 space-y-2">
            <legend className={legendCls}>Day pass (one per day)</legend>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1">
                <label htmlFor="fair-day-price" className={labelCls}>Price ($)</label>
                <input id="fair-day-price" inputMode="decimal" value={form.dayPass.price}
                  onChange={(e) => setForm({ ...form, dayPass: { ...form.dayPass, price: e.target.value } })} className={inputCls} />
              </div>
              <div className="space-y-1">
                <label htmlFor="fair-day-cap" className={labelCls}>Per day</label>
                <input id="fair-day-cap" inputMode="numeric" value={form.dayPass.capacity}
                  onChange={(e) => setForm({ ...form, dayPass: { ...form.dayPass, capacity: e.target.value } })} className={inputCls} />
              </div>
            </div>
          </fieldset>

          <fieldset className="border border-white/10 p-3 space-y-2">
            <legend className={legendCls}>Multi-day pass</legend>
            <label className="flex items-center gap-2 text-sm text-white">
              <input type="checkbox" checked={form.multi.enabled} onChange={(e) => setForm({ ...form, multi: { ...form.multi, enabled: e.target.checked } })} />
              Sell a pass for several days
            </label>
            {form.multi.enabled && (
              <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
                <div className="space-y-1">
                  <label htmlFor="fair-multi-days" className={labelCls}>Valid on</label>
                  <select id="fair-multi-days" value={form.multi.days} className={inputCls}
                    onChange={(e) => setForm({ ...form, multi: { ...form.multi, days: e.target.value } })}>
                    <option value="">Every day</option>
                    {Array.from({ length: Math.max(0, form.days.length - 2) }, (_, i) => i + 2).map((k) => (
                      <option key={k} value={String(k)}>Any {k} days</option>
                    ))}
                  </select>
                </div>
                <div className="space-y-1">
                  <label htmlFor="fair-multi-price" className={labelCls}>Price ($)</label>
                  <input id="fair-multi-price" inputMode="decimal" value={form.multi.price}
                    onChange={(e) => setForm({ ...form, multi: { ...form.multi, price: e.target.value } })} className={inputCls} />
                </div>
                <div className="space-y-1">
                  <label htmlFor="fair-multi-cap" className={labelCls}>How many</label>
                  <input id="fair-multi-cap" inputMode="numeric" value={form.multi.capacity}
                    onChange={(e) => setForm({ ...form, multi: { ...form.multi, capacity: e.target.value } })} className={inputCls} />
                </div>
              </div>
            )}
          </fieldset>

          {productFields('any', 'Any-day pass', 'Sell a pass for any one day the holder picks at the gate', 'How many')}
          {productFields('parking', 'Parking', 'Sell parking (its own code, scanned at the lot)', 'Spaces')}
          {productFields('camping', 'Camping', 'Sell camping (its own code, scanned at the lot)', 'Sites')}

          {errors.length > 0 ? (
            <div role="alert" data-testid="fair-setup-errors">
              <ul className="text-sm text-red-300 space-y-1">
                {errors.map((e) => <li key={e}>{e}</li>)}
              </ul>
            </div>
          ) : plan && (
            <div className="space-y-1" data-testid="fair-setup-preview">
              <p className={labelCls}>This creates</p>
              <ul className="text-sm text-white/80 list-disc pl-5 space-y-0.5">
                {planSummary(plan).map((l) => <li key={l}>{l}</li>)}
              </ul>
            </div>
          )}

          <div className="flex gap-3">
            <button type="button" disabled={busy || !plan} onClick={() => void create()}
              className="flex-1 px-4 py-3 bg-brand-primary text-black text-[11px] font-black uppercase tracking-widest disabled:opacity-50">
              {busy ? 'Creating…' : 'Create passes and lists'}
            </button>
            <button type="button" onClick={() => setOpen(false)}
              className="px-4 py-3 border border-white/20 text-white/80 text-[11px] font-black uppercase tracking-widest">
              Cancel
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
