// ReferralRewardsPanel — organizer rule editor + referral leaderboard
// (mig 20260926030000).
//
// "Every N friends' tickets earns a reward": the reward is a single-use
// voucher bound to the fan's confirmed email, on a ticket type of this event
// or a later one (free, a set price, or a % / amount off). Rewards are issued
// and, if friends' tickets are voided before the fan uses the reward,
// revoked by the database; this panel only edits the rule. Owner / manager
// edit; finance sees the rule and the leaderboard read-only.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Gift } from 'lucide-react';
import type { Event } from '../types';
import { useToast } from '../context/ToastContext';
import {
  deleteRewardRule, getRewardRule, referralLeaderboard, setRewardRule,
  type LeaderboardRow, type RewardRuleState,
} from '../lib/referrals';
import {
  describeReward, rewardPrice, toDraft, validateRuleDraft,
  type RewardKind, type RewardRuleDraft,
} from '../lib/referralRewards';
import { formatCurrency } from '../lib/utils';

type Scope = 'event' | 'org';

const inputCls = 'px-2 py-1.5 border border-slate-200 rounded text-sm disabled:bg-slate-50 disabled:text-slate-400';
const labelCls = 'text-[10px] font-black text-slate-400 uppercase tracking-widest';

export default function ReferralRewardsPanel({ event, canManage }: { event: Event; canManage: boolean }) {
  const { toast } = useToast();
  const currency = event.currency || 'USD';
  const [state, setState] = useState<RewardRuleState | null>(null);
  const [board, setBoard] = useState<LeaderboardRow[]>([]);
  const [scope, setScope] = useState<Scope>('event');
  const [draft, setDraft] = useState<RewardRuleDraft>(toDraft(null));
  const [valueText, setValueText] = useState('0');
  const [saving, setSaving] = useState(false);
  const [loadError, setLoadError] = useState(false);

  const load = useCallback(async () => {
    try {
      const [s, b] = await Promise.all([getRewardRule(event.id), referralLeaderboard(event.id)]);
      setState(s);
      setBoard(b);
      setLoadError(false);
    } catch (err) {
      console.error('referral rewards load failed:', err);
      setLoadError(true);
    }
  }, [event.id]);

  useEffect(() => { void load(); }, [load]);

  // Reset the form whenever the scope or the saved rules change.
  useEffect(() => {
    if (!state) return;
    const rule = scope === 'event' ? state.eventRule : state.orgDefault;
    const d = toDraft(rule);
    setDraft(d);
    setValueText(d.kind === 'percent_off' ? String(d.value) : (d.value / 100).toFixed(2));
  }, [state, scope]);

  const options = state?.rewardOptions ?? [];
  // null reward event = the referral's own event (this one, for an event rule).
  const rewardEvent = draft.rewardEventId
    ? options.find((o) => o.id === draft.rewardEventId)
    : scope === 'event' ? options.find((o) => o.id === event.id) : undefined;
  const tiers = rewardEvent?.tiers ?? [];
  const tier = tiers.find((t) => t.id === draft.rewardTierId);

  const parsedValue = useMemo(() => {
    const n = Number(valueText);
    if (!Number.isFinite(n) || n < 0) return -1;
    return draft.kind === 'percent_off' ? Math.round(n) : Math.round(n * 100);
  }, [valueText, draft.kind]);
  const candidate: RewardRuleDraft = { ...draft, value: parsedValue };
  const problem = validateRuleDraft(candidate, { orgDefault: scope === 'org' });

  const set = <K extends keyof RewardRuleDraft>(k: K, v: RewardRuleDraft[K]) => setDraft((d) => ({ ...d, [k]: v }));

  const save = async () => {
    if (problem) { toast({ kind: 'warn', message: problem }); return; }
    setSaving(true);
    try {
      await setRewardRule(scope === 'event' ? { eventId: event.id } : { eventId: null, orgId: event.orgId }, candidate);
      toast({ kind: 'success', message: scope === 'event' ? 'Referral reward saved.' : 'Org default saved.' });
      await load();
    } catch (err: any) {
      console.error('setRewardRule failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not save the reward.' });
    } finally {
      setSaving(false);
    }
  };

  const remove = async () => {
    const rule = scope === 'event' ? state?.eventRule : state?.orgDefault;
    if (!rule) return;
    setSaving(true);
    try {
      await deleteRewardRule(rule.id);
      toast({ kind: 'success', message: 'Rule removed. Rewards already issued stay valid.' });
      await load();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not remove the rule.' });
    } finally {
      setSaving(false);
    }
  };

  const savedRule = scope === 'event' ? state?.eventRule : state?.orgDefault;
  const disabled = !canManage || saving;
  const preview = tier && draft.kind !== 'price'
    ? ` Fans pay ${formatCurrency(rewardPrice(draft.kind, Math.max(0, parsedValue), tier.price), currency)} (today's price).`
    : '';

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Gift className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Referral rewards</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Fans share their own link from their ticket. Every few friends' tickets earn them a one-time code, tied to
        their confirmed email. Their own purchases don't count. If friends' tickets are voided before the fan uses
        the code, the code is cancelled; a code already used stays used.
      </p>

      {loadError && <p className="text-xs text-rose-600 mb-4">Could not load referral rewards.</p>}

      <div className="flex gap-2 mb-4">
        {(['event', 'org'] as Scope[]).map((s) => (
          <button
            key={s}
            type="button"
            onClick={() => setScope(s)}
            className={`px-3 py-1.5 rounded-lg text-xs font-bold ${scope === s ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-600'}`}
          >
            {s === 'event' ? 'This event' : 'Org default'}
          </button>
        ))}
        {state && (
          <span className="ml-auto self-center text-xs text-slate-400">
            {state.applies === 'event' ? 'This event uses its own rule.'
              : state.applies === 'org' ? 'This event uses the org default.'
              : 'No rule yet: no rewards are issued.'}
          </span>
        )}
      </div>
      {scope === 'org' && (
        <p className="text-xs text-slate-400 mb-3">Used by every event without its own rule.</p>
      )}

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
        <label className="flex items-center gap-3 text-sm text-slate-700 md:col-span-3">
          <input type="checkbox" checked={draft.enabled} disabled={disabled}
            onChange={(e) => set('enabled', e.target.checked)} className="h-4 w-4 rounded border-slate-300" />
          Rewards on
        </label>
        <label className="flex flex-col gap-1">
          <span className={labelCls}>Friends' tickets per reward</span>
          <input type="number" min={1} max={100} value={draft.everyN} disabled={disabled}
            onChange={(e) => set('everyN', Math.round(Number(e.target.value)))} className={inputCls} />
        </label>
        <label className="flex flex-col gap-1">
          <span className={labelCls}>Max rewards per fan</span>
          <input type="number" min={1} max={20} value={draft.maxRewardsPerFan} disabled={disabled}
            onChange={(e) => set('maxRewardsPerFan', Math.round(Number(e.target.value)))} className={inputCls} />
        </label>
        <label className="flex items-center gap-3 text-sm text-slate-700 self-end pb-1.5">
          <input type="checkbox" checked={draft.countFreeClaims} disabled={disabled}
            onChange={(e) => set('countFreeClaims', e.target.checked)} className="h-4 w-4 rounded border-slate-300" />
          Count free tickets too
        </label>

        <label className="flex flex-col gap-1">
          <span className={labelCls}>Reward is for</span>
          <select value={draft.rewardEventId ?? ''} disabled={disabled} className={inputCls}
            onChange={(e) => setDraft((d) => ({ ...d, rewardEventId: e.target.value || null, rewardTierId: null }))}>
            <option value="">{scope === 'event' ? 'This event' : "The fan's event"}</option>
            {options.filter((o) => scope === 'org' || o.id !== event.id).map((o) => (
              <option key={o.id} value={o.id}>{o.name || 'Untitled event'}</option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1">
          <span className={labelCls}>Ticket type</span>
          <select value={draft.rewardTierId ?? ''} disabled={disabled} className={inputCls}
            onChange={(e) => set('rewardTierId', e.target.value || null)}>
            <option value="">Any ticket type</option>
            {tiers.map((t) => (
              <option key={t.id} value={t.id}>
                {(t.name || 'Ticket')} · {formatCurrency(t.price, currency)}{t.visibility && t.visibility !== 'public' ? ' · hidden' : ''}
              </option>
            ))}
          </select>
        </label>
        <div className="flex flex-col gap-1">
          <span className={labelCls}>Reward</span>
          <div className="flex gap-2">
            <select value={draft.kind} disabled={disabled} className={inputCls}
              onChange={(e) => { set('kind', e.target.value as RewardKind); setValueText(e.target.value === 'percent_off' ? '100' : '0'); }}>
              <option value="price">Set price</option>
              <option value="percent_off">% off</option>
              <option value="amount_off">Amount off</option>
            </select>
            <input type="number" min={0} step={draft.kind === 'percent_off' ? 1 : 0.01} value={valueText} disabled={disabled}
              onChange={(e) => setValueText(e.target.value)} className={`${inputCls} w-24`}
              aria-label={draft.kind === 'percent_off' ? 'Percent off' : 'Amount'} />
          </div>
        </div>
        <label className="flex items-center gap-3 text-sm text-slate-700 md:col-span-3">
          <input type="checkbox" checked={draft.bypassCapacity} disabled={disabled}
            onChange={(e) => set('bypassCapacity', e.target.checked)} className="h-4 w-4 rounded border-slate-300" />
          Reward codes work even when sold out
        </label>
      </div>

      <p className="text-xs text-slate-500 mb-4">
        {problem ?? `Every ${draft.everyN} friends' ticket${draft.everyN === 1 ? '' : 's'} earns ${describeReward(draft.kind, Math.max(0, parsedValue), { currency, tierName: tier?.name })}, up to ${draft.maxRewardsPerFan} per fan.${preview}`}
      </p>

      {canManage && (
        <div className="flex gap-2 mb-6">
          <button type="button" onClick={save} disabled={saving || !!problem}
            className="px-4 py-2 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all">
            {saving ? 'Saving…' : 'Save reward'}
          </button>
          {savedRule && (
            <button type="button" onClick={remove} disabled={saving}
              className="px-4 py-2 bg-slate-100 hover:bg-slate-200 text-slate-600 rounded-lg font-bold text-xs">
              {scope === 'event' ? 'Remove (use org default)' : 'Remove org default'}
            </button>
          )}
        </div>
      )}

      <h4 className="text-xs font-bold text-slate-700 mb-2">Top referrers</h4>
      {board.length === 0 ? (
        <p className="text-xs text-slate-400">No referred tickets yet.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-[10px] uppercase tracking-widest text-slate-400">
                <th className="py-1 pr-2">#</th>
                <th className="py-1 pr-2">Fan</th>
                <th className="py-1 pr-2 text-right">Tickets</th>
                <th className="py-1 pr-2 text-right">Friends</th>
                <th className="py-1 pr-2 text-right">Rewards</th>
                <th className="py-1 text-right">Used</th>
              </tr>
            </thead>
            <tbody>
              {board.map((r) => (
                <tr key={r.rank} className="border-t border-slate-100">
                  <td className="py-1.5 pr-2 text-slate-400">{r.rank}</td>
                  <td className="py-1.5 pr-2 text-slate-700">{r.label}</td>
                  <td className="py-1.5 pr-2 text-right">{r.tickets}</td>
                  <td className="py-1.5 pr-2 text-right">{r.friends}</td>
                  <td className="py-1.5 pr-2 text-right">{r.rewardsIssued}</td>
                  <td className="py-1.5 text-right">{r.rewardsRedeemed}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
