// CommissionMethodsPanel — how promoter commissions are funded (mig
// 20261104190000, docs/organizer-guide.md "How promoter commissions are
// paid"). On the Promoters page: the org default with plain explanations, the
// holdback, per-event and per-promoter overrides, and each promoter's balance
// including netting. The RPCs enforce roles (owner / manager change, finance
// reads; the split-at-sale switch is the owner's); canWrite only hides controls.

import { useEffect, useState } from 'react';
import { AlertTriangle, Lock, RefreshCw, Scale, XCircle } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCurrency } from '../lib/utils';
import {
  holdbackText, METHOD_INFO, METHODS, methodLabel, needsFutureOnlyConfirm, nettingLine, parseHoldbackDays,
  transferKindLabel, transferStatusLabel, type CommissionMethod, type PromoterBalance,
} from '../lib/commissionMethods';
import {
  cancelCommissionTransfer, getCommissionBalances, getCommissionSettings, runCommissionTransfers, saveCommissionSettings,
  setEventCommissionMethod, setPromoterCommissionMethod, type CommissionSettings, type CommissionTransferRow,
} from '../lib/commissionMethodsApi';

const money = (cents: number, currency?: string | null) => formatCurrency(cents / 100, (currency || 'usd').toUpperCase());
const field = 'bg-black border border-white/20 px-2 py-1 text-sm text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
const label = 'type text-[10px] uppercase tracking-widest text-white/50';
const day = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString() : '');

export default function CommissionMethodsPanel({ orgId, canWrite, isOwner }: { orgId: string; canWrite: boolean; isOwner: boolean }) {
  const { toast } = useToast();
  const [s, setS] = useState<CommissionSettings | null>(null);
  const [balances, setBalances] = useState<{ promoters: PromoterBalance[]; organizer: { currency: string; owedToExosCents: number; since: string | null; overdue: boolean }[]; transfers: CommissionTransferRow[] } | null>(null);
  const [method, setMethod] = useState<CommissionMethod>('manual');
  const [holdback, setHoldback] = useState('3');
  const [alertDays, setAlertDays] = useState('30');
  const [busy, setBusy] = useState(false);
  const [confirmFuture, setConfirmFuture] = useState<Record<string, boolean>>({});

  const load = async () => {
    const [st, b] = await Promise.all([getCommissionSettings(orgId), getCommissionBalances(orgId)]);
    setS(st);
    setBalances(b);
    if (st) { setMethod(st.defaultMethod); setHoldback(String(st.holdbackDays)); setAlertDays(String(st.nettingAlertDays)); }
  };
  useEffect(() => { void load(); }, [orgId]);

  // Before the migration the RPC doesn't exist: nothing to show.
  if (!s) return null;

  const act = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try { await fn(); toast({ kind: 'success', message: ok }); await load(); }
    catch (err: any) { toast({ kind: 'error', message: err?.message || 'Could not save.' }); }
    finally { setBusy(false); }
  };

  const save = () => {
    const days = parseHoldbackDays(holdback);
    const alert = Number(alertDays);
    if (days === null) { toast({ kind: 'error', message: 'The holdback is 0 to 30 days.' }); return; }
    if (!Number.isInteger(alert) || alert < 1 || alert > 365) { toast({ kind: 'error', message: 'The overdue alert is 1 to 365 days.' }); return; }
    void act(() => saveCommissionSettings(orgId, { defaultMethod: method, holdbackDays: days, nettingAlertDays: alert }),
      'Saved. Events that have sold keep the method their sales used.');
  };

  return (
    <div className="bg-[#111] border border-white/10 p-4 mb-8 space-y-6">
      <div>
        <h2 className="disp text-lg uppercase tracking-wide text-white flex items-center gap-2"><Scale className="w-4 h-4 text-brand-primary" /> How commissions are paid</h2>
        <p className="text-[11px] text-white/60">
          Pick where the money for a promoter's commission comes from. The org default applies to every event; an event or a promoter can
          use another one (the promoter's wins, then the event's). Buyers see the same price whichever you pick.
        </p>
      </div>

      <fieldset className="space-y-2" disabled={!canWrite || busy}>
        <legend className={label}>Org default</legend>
        {METHODS.map((m) => {
          const info = METHOD_INFO[m];
          return (
            <label key={m} className={`flex gap-3 border px-3 py-2 cursor-pointer ${method === m ? 'border-brand-primary' : 'border-white/10'}`}>
              <input type="radio" name="commission-method" value={m} checked={method === m} onChange={() => setMethod(m)} className="mt-1" />
              <span className="min-w-0">
                <span className="block text-sm font-black text-white">{info.label}</span>
                <span className="block text-[11px] text-white/70">{info.short}</span>
                <span className="block text-[11px] text-white/50">{info.how}</span>
                {info.needs.length > 0 && <span className="block text-[11px] text-white/40">Needs: {info.needs.join('; ')}.</span>}
              </span>
            </label>
          );
        })}
        <div className="flex flex-wrap items-end gap-4 pt-2">
          <label className="block">
            <span className={label}>Holdback (days after the event)</span>
            <input className={`${field} w-20 block`} inputMode="numeric" value={holdback} onChange={(e) => setHoldback(e.target.value)} aria-label="Holdback days" />
          </label>
          <label className="block">
            <span className={label}>Flag unpaid refunds after (days)</span>
            <input className={`${field} w-20 block`} inputMode="numeric" value={alertDays} onChange={(e) => setAlertDays(e.target.value)} aria-label="Overdue alert days" />
          </label>
          {canWrite && (
            <button onClick={save} disabled={busy} className="bg-brand-primary text-black px-4 py-2 text-[11px] font-black uppercase disabled:opacity-50">Save</button>
          )}
        </div>
        <p className="text-[11px] text-white/50">
          {holdbackText(parseHoldbackDays(holdback) ?? s.holdbackDays)} Applies to every method{s.configured ? '' : ' once you save'}.
          A refund after a promoter was paid is taken off their next commission, never pulled back from their account.
        </p>
      </fieldset>

      <div className="border border-white/10 p-3 flex flex-wrap items-center gap-3">
        <div className="flex-1 min-w-0">
          <p className={label}>Split at sale</p>
          <p className="text-[11px] text-white/60">
            {s.splitAtSaleEnabled ? 'On for this org.' : 'Off.'} Orders on split-at-sale events are charged on the Exos account, and Exos handles
            disputes on those charges. Your Stripe account must be an Express account{s.organizerAccount ? '' : ' (finish payment setup first)'}, and each promoter needs a
            Stripe payout account. Exos must also have it switched on; until both are on, those sales are recorded as manual.
            {!isOwner && ' Only the org owner can change this.'}
          </p>
        </div>
        {isOwner && (
          <button
            role="switch" aria-checked={s.splitAtSaleEnabled} disabled={busy}
            onClick={() => act(() => saveCommissionSettings(orgId, { defaultMethod: s.defaultMethod, holdbackDays: s.holdbackDays, splitAtSaleEnabled: !s.splitAtSaleEnabled }),
              !s.splitAtSaleEnabled ? 'Split at sale is on for this org.' : 'Split at sale is off for new orders.')}
            className={`px-4 py-2 text-[11px] font-black uppercase ${s.splitAtSaleEnabled ? 'bg-brand-primary text-black' : 'border border-white/20 text-white'}`}
          >
            {s.splitAtSaleEnabled ? 'Turn off' : 'Turn on'}
          </button>
        )}
      </div>

      {s.events.length > 0 && (
        <div>
          <p className={`${label} mb-2`}>Per event</p>
          <div className="space-y-1">
            {s.events.slice(0, 30).map((e) => (
              <div key={e.eventId} className="flex flex-wrap items-center gap-2 text-sm">
                <span className="flex-1 min-w-0 truncate text-white">{e.name}</span>
                {e.sold && <span className="type text-[10px] text-white/40 inline-flex items-center gap-1" title="Its first ticket sold: changes apply to future sales only"><Lock className="w-3 h-3" /> locked</span>}
                <select
                  className={field} disabled={!canWrite || busy} aria-label={`Commission method for ${e.name}`}
                  value={e.method ?? ''}
                  onChange={(ev) => {
                    const next = (ev.target.value || null) as CommissionMethod | null;
                    const eff = next ?? s.defaultMethod;
                    if (needsFutureOnlyConfirm(e, eff) && !confirmFuture[e.eventId]) {
                      toast({ kind: 'error', message: 'This event has sold. Tick "future sales only" first: sales so far keep their method.' });
                      return;
                    }
                    void act(() => setEventCommissionMethod(e.eventId, next, e.sold), `${e.name}: ${methodLabel(eff)}${e.sold ? ' for future sales' : ''}.`);
                  }}
                >
                  <option value="">Org default ({methodLabel(s.defaultMethod)})</option>
                  {METHODS.map((m) => <option key={m} value={m}>{METHOD_INFO[m].label}</option>)}
                </select>
                {e.sold && canWrite && (
                  <label className="type text-[10px] text-white/50 inline-flex items-center gap-1">
                    <input type="checkbox" checked={!!confirmFuture[e.eventId]} onChange={(ev) => setConfirmFuture({ ...confirmFuture, [e.eventId]: ev.target.checked })} />
                    future sales only
                  </label>
                )}
                <span className="type text-[10px] text-white/50 w-32 text-right">now: {methodLabel(e.effective)}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {s.promoters.length > 0 && (
        <div>
          <p className={`${label} mb-2`}>Per promoter (wins over the event)</p>
          <div className="space-y-1">
            {s.promoters.map((p) => (
              <div key={p.promoterId} className="flex flex-wrap items-center gap-2 text-sm">
                <span className="flex-1 min-w-0 truncate text-white">{p.name} <span className="type text-[10px] text-white/40">{p.code}</span></span>
                <span className={`type text-[10px] ${p.accountReady ? 'text-brand-primary' : 'text-white/40'}`}>{p.accountReady ? 'payout account ready' : 'no payout account'}</span>
                <select
                  className={field} disabled={!canWrite || busy} aria-label={`Commission method for ${p.name}`}
                  value={p.method ?? ''}
                  onChange={(ev) => void act(() => setPromoterCommissionMethod(p.promoterId, (ev.target.value || null) as CommissionMethod | null),
                    `${p.name}: ${ev.target.value ? methodLabel(ev.target.value) : 'event / org default'} for future sales.`)}
                >
                  <option value="">Event / org default</option>
                  {METHODS.map((m) => <option key={m} value={m}>{METHOD_INFO[m].label}</option>)}
                </select>
              </div>
            ))}
          </div>
        </div>
      )}

      {balances && (
        <div>
          <div className="flex items-center gap-2 mb-2">
            <p className={`${label} flex-1`}>Balances</p>
            {canWrite && (
              <button disabled={busy} onClick={() => act(() => runCommissionTransfers(orgId), 'Checked what is due. Transfers go out when the switches are on (test runs otherwise).')}
                className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-white/60 hover:text-white">
                <RefreshCw className="w-3 h-3" /> Pay what's due now
              </button>
            )}
          </div>
          {balances.promoters.length === 0 ? (
            <p className="text-[11px] text-white/40 italic">No commissions yet.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-[11px] text-white/80">
                <thead><tr className={label}>
                  <th className="text-left py-1">Promoter</th><th className="text-right">Held</th><th className="text-right">You pay</th>
                  <th className="text-right">Exos pays</th><th className="text-right">Sending</th><th className="text-right">Paid</th><th className="text-right">Balance</th>
                </tr></thead>
                <tbody>
                  {balances.promoters.map((b) => {
                    const line = nettingLine(b, (c) => money(c, b.currency));
                    return (
                      <tr key={`${b.promoterId}-${b.currency}`} className="border-t border-white/5 align-top">
                        <td className="py-1">
                          {b.name}
                          {!b.accountReady && b.payableByExosCents > 0 && <span className="block text-white/40">waiting for their payout account</span>}
                          {line && <span className={`block ${b.nettingOverdue ? 'text-red-300' : 'text-white/50'}`}>{b.nettingOverdue && <AlertTriangle className="inline w-3 h-3 mr-1" />}{line}</span>}
                        </td>
                        <td className="text-right">{money(b.heldCents, b.currency)}{b.heldUntil && <span className="block text-white/40">until {day(b.heldUntil)}</span>}</td>
                        <td className="text-right">{money(b.payableByYouCents, b.currency)}</td>
                        <td className="text-right">{money(b.payableByExosCents, b.currency)}</td>
                        <td className="text-right">{money(b.processingCents, b.currency)}</td>
                        <td className="text-right">{money(b.paidCents, b.currency)}</td>
                        <td className={`text-right font-black ${b.balanceCents < 0 ? 'text-red-300' : 'text-white'}`}>{money(b.balanceCents, b.currency)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
          {balances.organizer.map((o) => (
            <p key={o.currency} className={`text-[11px] mt-2 ${o.overdue ? 'text-red-300' : 'text-white/60'}`}>
              {o.owedToExosCents > 0
                ? `You owe Exos ${money(o.owedToExosCents, o.currency)} for split-at-sale refunds after your share was paid; it comes off your next split order.`
                : `Exos owes you ${money(-o.owedToExosCents, o.currency)}; it is added to your next split order.`}
              {o.overdue && ' Open for a while: contact Exos to settle it.'}
            </p>
          ))}
          {balances.transfers.length > 0 && (
            <div className="mt-3 space-y-1">
              <p className={label}>Exos transfers</p>
              {balances.transfers.slice(0, 12).map((t) => (
                <div key={t.id} className="flex flex-wrap items-center gap-2 text-[11px] text-white/70">
                  <span className="w-32">{transferKindLabel(t.kind)}{t.promoter ? `: ${t.promoter}` : ''}</span>
                  <span>{money(t.amountCents, t.currency)}{t.nettedCents !== 0 && <span className="text-white/40"> ({money(t.grossCents, t.currency)} less {money(t.nettedCents, t.currency)} netted)</span>}</span>
                  <span className="type text-[10px] uppercase">{transferStatusLabel(t.status)}</span>
                  {t.error && <span className="text-red-300 truncate max-w-xs" title={t.error}>{t.error}</span>}
                  {t.alert && <span className="text-red-300 truncate max-w-xs" title={t.alert}><AlertTriangle className="inline w-3 h-3" /> {t.alert}</span>}
                  {canWrite && t.status === 'failed' && (
                    <button disabled={busy} onClick={() => act(() => runCommissionTransfers(orgId, t.id), 'Retried.')} className="font-black uppercase text-white/60 hover:text-white">Retry</button>
                  )}
                  {canWrite && ['planned', 'failed', 'dry_run'].includes(t.status) && (
                    <button disabled={busy} onClick={() => act(() => cancelCommissionTransfer(t.id), 'Cancelled; those sales are unpaid again.')} className="inline-flex items-center gap-1 font-black uppercase text-white/40 hover:text-white">
                      <XCircle className="w-3 h-3" /> Cancel
                    </button>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
