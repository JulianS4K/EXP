// Organizer fee rules (mig 20261027100000, docs/fees.md).
//
// Self-contained CRUD (not part of any form submit), in two places:
//   * Org settings (no eventId): the org's rules, inherited by every event.
//   * Event editor (eventId): use the org's rules or not (all, or skip some),
//     the event's own rules (optionally for some tiers only), and what buyers
//     will see per tier.
// Owners and managers edit (canEdit); finance sees the rules read-only. RLS
// enforces the same.
//
// A passed-on fee is inside the all-in price buyers see everywhere (no fee line
// at checkout); an absorbed fee is the organizer's cost, recorded per order.

import { useEffect, useMemo, useState } from 'react';
import { Plus, Trash2, Receipt, Pencil, X } from 'lucide-react';
import {
  deleteFeeRule, effectiveFeeRules, feeRuleProblems, getEventFeeSettings, listEventFeeRules, listOrgFeeRules,
  saveEventFeeSettings, saveFeeRule, MAX_EFFECTIVE_RULES,
  type EventFeeSettings, type FeeRuleInput, type FeeRuleRow,
} from '../lib/feeRules';
import { addonPassedOnFees, tierPassedOnFees } from '../lib/fees';
import { buyerTierPrice, includedFees } from '../lib/pricing';
import { listTaxableProducts, listTaxRules } from '../lib/tax';
import { formatCurrency } from '../lib/utils';
import { useToast } from '../context/ToastContext';

const inputCls =
  'bg-slate-50 border-2 border-transparent rounded-2xl py-3 px-5 text-slate-900 font-bold w-full ' +
  'focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary focus:bg-white transition-all shadow-inner';
const labelCls = 'text-[10px] font-black text-slate-400 uppercase tracking-widest';

export interface FeeRulesTier {
  id: string;
  name: string;
  price: number;
  priceSchedule?: unknown;
}

interface Props {
  orgId: string;
  /** Event mode when set. */
  eventId?: string;
  /** Event mode: the event's saved tiers, for tier-only rules and the preview. */
  tiers?: FeeRulesTier[];
  currency?: string;
  canEdit: boolean;
}

interface Draft {
  id?: string;
  name: string;
  recipient: string;
  kind: 'passed_on' | 'absorbed';
  calc: 'fixed' | 'percent';
  value: string;
  cap: string;
  per: 'ticket' | 'order';
  taxable: boolean;
  appliesToAddons: boolean;
  tierIds: string[];
  active: boolean;
}

const BLANK: Draft = {
  name: '', recipient: 'org', kind: 'passed_on', calc: 'fixed', value: '', cap: '', per: 'ticket',
  taxable: true, appliesToAddons: false, tierIds: [], active: true,
};

function toInput(d: Draft, sortOrder: number): FeeRuleInput {
  const v = parseFloat(d.value);
  const cap = parseFloat(d.cap);
  return {
    name: d.name, recipient: d.recipient, kind: d.kind, calc: d.calc,
    percent: d.calc === 'percent' && Number.isFinite(v) ? Math.round(v * 1000) / 1000 : null,
    amountCents: d.calc === 'fixed' && Number.isFinite(v) ? Math.round(v * 100) : null,
    capCents: d.calc === 'percent' && d.cap.trim() && Number.isFinite(cap) ? Math.round(cap * 100) : null,
    per: d.per, taxable: d.kind === 'passed_on' ? d.taxable : false, appliesToAddons: d.appliesToAddons,
    tierIds: d.tierIds.length ? d.tierIds : null, active: d.active, sortOrder,
  };
}

function fromRow(r: FeeRuleRow): Draft {
  return {
    id: r.id, name: r.name, recipient: r.recipient, kind: r.kind, calc: r.calc,
    value: r.calc === 'percent' ? String(r.percent ?? '') : ((r.amountCents ?? 0) / 100).toFixed(2),
    cap: r.capCents != null ? (r.capCents / 100).toFixed(2) : '', per: r.per, taxable: r.taxable,
    appliesToAddons: r.appliesToAddons, tierIds: r.tierIds ?? [], active: r.active,
  };
}

function describe(r: FeeRuleRow, currency: string): string {
  const amount = r.calc === 'percent'
    ? `${r.percent}%${r.capCents != null ? ` (max ${formatCurrency(r.capCents / 100, currency)})` : ''}`
    : formatCurrency((r.amountCents ?? 0) / 100, currency);
  return [
    amount,
    r.per === 'order' ? 'per order' : r.appliesToAddons ? 'per ticket + add-on' : 'per ticket',
    r.kind === 'passed_on' ? `passed on${r.taxable ? '' : ', not taxed'}` : 'absorbed',
    `to ${r.recipient}`,
  ].join(' · ');
}

export default function FeeRulesEditor({ orgId, eventId, tiers = [], currency = 'USD', canEdit }: Props) {
  const { toast } = useToast();
  const [orgRules, setOrgRules] = useState<FeeRuleRow[]>([]);
  const [eventRules, setEventRules] = useState<FeeRuleRow[]>([]);
  const [settings, setSettings] = useState<EventFeeSettings>({ inheritOrgRules: true, skippedOrgRuleIds: [] });
  const [taxPct, setTaxPct] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [unavailable, setUnavailable] = useState(false);
  const [busy, setBusy] = useState(false);
  const [draft, setDraft] = useState<Draft>({ ...BLANK });
  const [samplePrice, setSamplePrice] = useState('50');

  const mine = eventId ? eventRules : orgRules;

  const reload = async () => {
    try {
      const [o, e, s] = await Promise.all([
        listOrgFeeRules(orgId),
        eventId ? listEventFeeRules(eventId) : Promise.resolve([]),
        eventId ? getEventFeeSettings(eventId) : Promise.resolve({ inheritOrgRules: true, skippedOrgRuleIds: [] }),
      ]);
      setOrgRules(o); setEventRules(e); setSettings(s);
      if (eventId) {
        // Exclusive tax per tier, for the preview (what the storefront adds).
        try {
          const [rules, products] = await Promise.all([listTaxRules(eventId), listTaxableProducts(eventId)]);
          const pct: Record<string, number> = {};
          for (const p of products) {
            const r = rules.find((x) => x.id === p.taxRateId);
            if (p.kind === 'tier' && r && !r.priceIncludesTax) pct[p.id] = r.ratePercent;
          }
          setTaxPct(pct);
        } catch { setTaxPct({}); }
      }
    } catch (err) {
      console.error('fee rules load failed:', err);
      setUnavailable(true);
    } finally { setLoading(false); }
  };
  useEffect(() => { reload(); /* eslint-disable-next-line */ }, [orgId, eventId]);

  const effective = useMemo(
    () => effectiveFeeRules(orgRules, eventId ? eventRules : [], eventId ? settings : { inheritOrgRules: true, skippedOrgRuleIds: [] }),
    [orgRules, eventRules, settings, eventId],
  );

  const save = async () => {
    const input = toInput(draft, draft.id ? (mine.find((r) => r.id === draft.id)?.sortOrder ?? 0) : mine.length);
    const problems = feeRuleProblems(input);
    if (problems.length) { toast({ kind: 'error', message: problems[0] }); return; }
    setBusy(true);
    try {
      await saveFeeRule(orgId, eventId ?? null, input, draft.id);
      setDraft({ ...BLANK });
      await reload();
      toast({ kind: 'success', message: 'Fee rule saved.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save the fee rule.' });
    } finally { setBusy(false); }
  };

  const remove = async (r: FeeRuleRow) => {
    setBusy(true);
    try {
      await deleteFeeRule(r.id);
      if (draft.id === r.id) setDraft({ ...BLANK });
      await reload();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not delete the fee rule.' });
    } finally { setBusy(false); }
  };

  const updateSettings = async (next: EventFeeSettings) => {
    if (!eventId) return;
    const prev = settings;
    setSettings(next);
    try {
      await saveEventFeeSettings(eventId, orgId, next);
    } catch (e: any) {
      setSettings(prev);
      toast({ kind: 'error', message: e?.message || 'Could not save.' });
    }
  };

  if (loading || unavailable) return null;
  if (!canEdit && orgRules.length === 0 && eventRules.length === 0) return null;

  const sample = Math.max(0, parseFloat(samplePrice) || 0);
  const sampleFees = tierPassedOnFees(effective, '');
  const addonFees = addonPassedOnFees(effective);

  return (
    <section className="bg-white p-6 md:p-10 rounded-[2rem] border border-slate-100 shadow-xl space-y-6" aria-labelledby="fee-rules-h">
      <div className="flex items-center space-x-3">
        <Receipt className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 id="fee-rules-h" className="text-xs font-bold text-slate-400 uppercase tracking-widest leading-none">
          {eventId ? 'Fees for this event' : 'Fee rules'}
        </h2>
      </div>
      <p className="text-slate-500 text-xs font-bold -mt-2">
        A <strong>passed-on</strong> fee is paid by the buyer, inside the all-in price they see everywhere (no fee is
        added at checkout; receipts say what the price includes). An <strong>absorbed</strong> fee comes out of your
        revenue and is recorded per order. {eventId ? '' : 'Every event uses these unless it opts out.'}
        {' '}At most {MAX_EFFECTIVE_RULES} rules apply to an event. Not the Exos platform fee.
      </p>

      {eventId && orgRules.length > 0 && (
        <div className="space-y-2 bg-slate-50 rounded-2xl p-4">
          <label className="flex items-center gap-2 text-sm font-bold text-slate-700">
            <input type="checkbox" disabled={!canEdit} checked={settings.inheritOrgRules}
              onChange={(e) => updateSettings({ ...settings, inheritOrgRules: e.target.checked })} />
            Use the organization's fee rules
          </label>
          {settings.inheritOrgRules && orgRules.filter((r) => r.active).map((r) => (
            <label key={r.id} className="flex items-center gap-2 text-xs font-bold text-slate-500 pl-6">
              <input type="checkbox" disabled={!canEdit} checked={!settings.skippedOrgRuleIds.includes(r.id)}
                onChange={(e) => updateSettings({
                  ...settings,
                  skippedOrgRuleIds: e.target.checked
                    ? settings.skippedOrgRuleIds.filter((x) => x !== r.id)
                    : [...settings.skippedOrgRuleIds, r.id],
                })} />
              {r.name} <span className="text-slate-400">({describe(r, currency)})</span>
            </label>
          ))}
        </div>
      )}

      {mine.length > 0 && (
        <ul className="space-y-2">
          {mine.map((r) => (
            <li key={r.id} className="flex items-center justify-between gap-3 bg-slate-50 rounded-2xl px-5 py-3">
              <div className="min-w-0">
                <p className={`font-bold text-sm ${r.active ? 'text-slate-900' : 'text-slate-400 line-through'}`}>{r.name}</p>
                <p className="text-xs font-bold text-slate-400">
                  {describe(r, currency)}
                  {r.tierIds && ` · ${r.tierIds.map((id) => tiers.find((t) => t.id === id)?.name ?? 'a removed tier').join(', ')} only`}
                </p>
              </div>
              {canEdit && (
                <span className="flex items-center gap-3 shrink-0">
                  <button type="button" onClick={() => setDraft(fromRow(r))} className="text-slate-400 hover:text-slate-900" aria-label={`Edit ${r.name}`}>
                    <Pencil className="w-4 h-4" />
                  </button>
                  <button type="button" disabled={busy} onClick={() => remove(r)} className="text-slate-300 hover:text-red-500" aria-label={`Delete ${r.name}`}>
                    <Trash2 className="w-4 h-4" />
                  </button>
                </span>
              )}
            </li>
          ))}
        </ul>
      )}

      {canEdit && (
        <div className="space-y-4 border-t border-slate-100 pt-4">
          <div className="flex items-center justify-between">
            <p className={labelCls}>{draft.id ? 'Edit fee' : 'Add a fee'}</p>
            {draft.id && (
              <button type="button" onClick={() => setDraft({ ...BLANK })} className="text-slate-400 hover:text-slate-900 text-xs font-bold flex items-center gap-1">
                <X className="w-3 h-3" /> Cancel
              </button>
            )}
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <label className="space-y-1 sm:col-span-2">
              <span className={labelCls}>Name buyers and reports see</span>
              <input value={draft.name} maxLength={60} onChange={(e) => setDraft({ ...draft, name: e.target.value })}
                placeholder="Facility fee" className={inputCls} />
            </label>
            <label className="space-y-1">
              <span className={labelCls}>Who pays</span>
              <select value={draft.kind} className={inputCls}
                onChange={(e) => {
                  const kind = e.target.value as Draft['kind'];
                  setDraft({ ...draft, kind, per: kind === 'passed_on' ? 'ticket' : draft.per });
                }}>
                <option value="passed_on">Buyer (inside the price)</option>
                <option value="absorbed">We absorb it</option>
              </select>
            </label>
            <label className="space-y-1">
              <span className={labelCls}>For (reports)</span>
              <input value={draft.recipient} maxLength={40} list="fee-recipients" className={inputCls}
                onChange={(e) => setDraft({ ...draft, recipient: e.target.value })} />
              <datalist id="fee-recipients">
                <option value="org" /><option value="venue" /><option value="promoter" />
              </datalist>
            </label>
            <label className="space-y-1">
              <span className={labelCls}>Amount</span>
              <div className="flex gap-2">
                <select value={draft.calc} aria-label="Fixed or percent" className={`${inputCls} w-28`}
                  onChange={(e) => setDraft({ ...draft, calc: e.target.value as Draft['calc'] })}>
                  <option value="fixed">{currency.toUpperCase()}</option>
                  <option value="percent">%</option>
                </select>
                <input value={draft.value} inputMode="decimal" type="number" min={0} step={draft.calc === 'percent' ? '0.001' : '0.01'}
                  max={draft.calc === 'percent' ? 100 : undefined} placeholder={draft.calc === 'percent' ? '3' : '2.00'}
                  onChange={(e) => setDraft({ ...draft, value: e.target.value })} className={inputCls} />
              </div>
            </label>
            <label className="space-y-1">
              <span className={labelCls}>Charged</span>
              <select value={draft.per} className={inputCls} onChange={(e) => setDraft({ ...draft, per: e.target.value as Draft['per'] })}>
                <option value="ticket">Per ticket</option>
                <option value="order" disabled={draft.kind === 'passed_on'}>Per order (absorbed only)</option>
              </select>
            </label>
            {draft.calc === 'percent' && (
              <label className="space-y-1">
                <span className={labelCls}>Cap (optional)</span>
                <input value={draft.cap} type="number" min={0} step="0.01" inputMode="decimal" placeholder="none"
                  onChange={(e) => setDraft({ ...draft, cap: e.target.value })} className={inputCls} />
              </label>
            )}
          </div>
          <div className="flex flex-wrap gap-x-6 gap-y-2 text-xs font-bold text-slate-500">
            {draft.kind === 'passed_on' && (
              <label className="flex items-center gap-2">
                <input type="checkbox" checked={draft.taxable} onChange={(e) => setDraft({ ...draft, taxable: e.target.checked })} />
                Taxed like the ticket
              </label>
            )}
            <label className="flex items-center gap-2">
              <input type="checkbox" checked={draft.appliesToAddons} onChange={(e) => setDraft({ ...draft, appliesToAddons: e.target.checked })} />
              {draft.per === 'order' ? 'Count add-ons in the order total' : 'Also on each add-on'}
            </label>
            <label className="flex items-center gap-2">
              <input type="checkbox" checked={draft.active} onChange={(e) => setDraft({ ...draft, active: e.target.checked })} />
              Active
            </label>
          </div>
          {eventId && tiers.length > 0 && (
            <fieldset className="space-y-1">
              <legend className={labelCls}>Ticket types (none ticked = all)</legend>
              <div className="flex flex-wrap gap-x-6 gap-y-1">
                {tiers.map((t) => (
                  <label key={t.id} className="flex items-center gap-2 text-xs font-bold text-slate-500">
                    <input type="checkbox" checked={draft.tierIds.includes(t.id)}
                      onChange={(e) => setDraft({
                        ...draft,
                        tierIds: e.target.checked ? [...draft.tierIds, t.id] : draft.tierIds.filter((x) => x !== t.id),
                      })} />
                    {t.name}
                  </label>
                ))}
              </div>
            </fieldset>
          )}
          <button type="button" disabled={busy} onClick={save}
            className="w-full flex items-center justify-center space-x-2 bg-slate-900 hover:bg-slate-800 text-white py-3 rounded-2xl font-black uppercase tracking-tighter italic text-xs transition-all disabled:opacity-50">
            <Plus className="w-4 h-4" /><span>{busy ? 'Saving…' : draft.id ? 'Save fee' : 'Add fee'}</span>
          </button>
        </div>
      )}

      {/* What buyers will see: the all-in price, with the passed-on fees in it. */}
      <div className="border-t border-slate-100 pt-4 space-y-2" aria-live="polite">
        <p className={labelCls}>Buyers will see</p>
        {eventId ? (
          tiers.length === 0 ? <p className="text-xs font-bold text-slate-400">Save a ticket type to preview its price.</p> : (
            <ul className="space-y-1">
              {tiers.map((t) => {
                const fees = tierPassedOnFees(effective, t.id);
                const shown = buyerTierPrice({ price: t.price, priceSchedule: t.priceSchedule, exclusiveTaxPercent: taxPct[t.id] ?? 0, passedOnFees: fees });
                const inc = includedFees(t.price, fees);
                return (
                  <li key={t.id} className="flex justify-between gap-3 text-sm font-bold text-slate-700">
                    <span className="truncate">{t.name}</span>
                    <span className="shrink-0 text-right">
                      {formatCurrency(shown, currency)}
                      {inc.length > 0 && (
                        <span className="block text-[11px] text-slate-400">
                          includes {inc.map((f) => `${formatCurrency(f.amount, currency)} ${f.name.toLowerCase()}`).join(', ')}
                          {taxPct[t.id] ? ' + tax' : ''}
                        </span>
                      )}
                    </span>
                  </li>
                );
              })}
              {addonFees.length > 0 && (
                <li className="text-[11px] font-bold text-slate-400">
                  Add-ons also include {addonFees.map((f) => f.name.toLowerCase()).join(', ')}.
                </li>
              )}
            </ul>
          )
        ) : (
          <div className="flex items-center gap-3 text-sm font-bold text-slate-700">
            <label className="flex items-center gap-2">
              <span className="text-xs text-slate-400">A</span>
              <input value={samplePrice} type="number" min={0} step="0.01" inputMode="decimal" aria-label="Sample ticket price"
                onChange={(e) => setSamplePrice(e.target.value)} className="w-24 bg-slate-50 rounded-xl px-3 py-1.5 font-bold" />
              <span className="text-xs text-slate-400">ticket shows as</span>
            </label>
            <span>
              {formatCurrency(buyerTierPrice({ price: sample, passedOnFees: sampleFees }), currency)}
              <span className="text-xs text-slate-400"> + tax where it applies</span>
            </span>
          </div>
        )}
      </div>
    </section>
  );
}
