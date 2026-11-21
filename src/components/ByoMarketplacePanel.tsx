// Edit event → "Your own marketplace accounts" (mig 20261121214500;
// docs/marketplace/README.md "Your own marketplace accounts"): sell a share
// of each ticket type on StubHub, SeatGeek, Vivid Seats or Ticket Evolution
// with the organizer's OWN seller account. Those tickets are static PDF codes
// and pay no Exos fee. A DRY RUN: Exos sends nothing to the marketplaces yet;
// "Preview" shows exactly what it would send. The seats set aside here are
// held back from Exos checkout. Owner / manager (both calls check the role).

import { useCallback, useEffect, useState } from 'react';
import { Store } from 'lucide-react';
import { BYO_LABEL, loadByoView, minPctFor, pctProblem, previewByo, seatsFor, setByoAllocation, type ByoChannel, type ByoChannelPlan, type ByoView, BYO_NOT_YET } from '../lib/byoMarketplaces';

export default function ByoMarketplacePanel({ eventId, orgId }: { eventId: string; orgId: string }) {
  const [view, setView] = useState<ByoView | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [plan, setPlan] = useState<ByoChannelPlan[] | null>(null);

  const reload = useCallback(() => {
    loadByoView(eventId)
      .then((v) => {
        setView(v);
        setDraft(Object.fromEntries(v.channels.map((c) => [c.channel, String(c.pct)])));
      })
      .catch((e) => setLoadError(e instanceof Error ? e.message : 'Could not load your marketplace accounts.'));
  }, [eventId]);
  useEffect(reload, [reload]);

  const save = async (channel: ByoChannel) => {
    const ch = view?.channels.find((c) => c.channel === channel);
    if (!ch) return;
    const pct = Number(draft[channel]);
    const problem = pctProblem(ch, pct, BYO_LABEL[channel]);
    setError(problem);
    setSaved(null);
    if (problem) return;
    setBusy(channel);
    try {
      await setByoAllocation(eventId, channel, pct);
      setSaved(`${BYO_LABEL[channel]}: ${pct}% saved.`);
      setPlan(null);
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the share.');
    } finally {
      setBusy(null);
    }
  };

  const preview = async () => {
    setBusy('preview');
    setError(null);
    try {
      setPlan((await previewByo(orgId, eventId)).channels);
    } catch (e) {
      setPlan(null);
      setError(e instanceof Error ? e.message : 'Preview failed.');
    } finally {
      setBusy(null);
    }
  };

  return (
    <section data-testid="byo-marketplace-panel" aria-labelledby="byo-title"
      className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-4">
      <div className="flex items-center gap-2">
        <Store className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h2 id="byo-title" className="text-sm font-black text-slate-900 uppercase tracking-widest">Your own marketplace accounts</h2>
        <span className="ml-auto text-[10px] font-bold uppercase tracking-widest rounded-full bg-amber-100 text-amber-900 px-2 py-0.5">Dry run</span>
      </div>
      <p className="text-xs text-slate-600">
        Sell a share of each ticket type on a marketplace with your own seller account. Those tickets are static PDF codes
        and pay no Exos fee, at any event size. The seats you set aside here are held back from Exos checkout. This is a
        preview: Exos sends nothing to the marketplaces yet.
      </p>
      {loadError && <p role="alert" className="text-[11px] text-rose-800">{loadError}</p>}

      {view && (
        <ul className="space-y-4">
          {view.channels.map((ch) => {
            const label = BYO_LABEL[ch.channel];
            const pct = Number(draft[ch.channel] ?? ch.pct);
            // Not supported yet (BYO_NOT_YET): nothing to set, unless an older
            // share is still there to release.
            const notYet = BYO_NOT_YET.has(ch.channel) && !ch.own;
            return (
              <li key={ch.channel} data-testid={`byo-${ch.channel}`} className="border border-slate-200 rounded-xl p-4 space-y-2">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-bold text-slate-900">{label}</span>
                  <span className={`text-[11px] ${ch.connected ? 'text-emerald-800' : 'text-slate-500'}`}>
                    {ch.connected ? 'Seller account connected' : 'Not connected (Org settings → Integrations)'}
                  </span>
                  {ch.network_ticked && <span className="text-[11px] text-amber-900">Ticked under Distribution: the Exos network sells it.</span>}
                  {notYet && <span className="text-[11px] text-slate-600">Not supported yet with your own account.</span>}
                </div>
                <div className="flex flex-wrap items-end gap-2">
                  <label className="text-[11px] font-bold text-slate-700">
                    Share of each ticket type (%)
                    <input type="number" min={ch.min_pct} max={100} step={0.5} inputMode="decimal"
                      aria-label={`${label} share (%)`}
                      value={draft[ch.channel] ?? ''}
                      onChange={(e) => setDraft((d) => ({ ...d, [ch.channel]: e.target.value }))}
                      disabled={notYet}
                      className="mt-1 block w-28 rounded-lg border border-slate-300 px-2 py-1 text-sm" />
                  </label>
                  <button type="button" onClick={() => void save(ch.channel)} disabled={busy !== null || notYet}
                    className="rounded-lg bg-slate-900 text-white text-xs font-bold px-3 py-2 disabled:opacity-50">
                    {busy === ch.channel ? 'Saving…' : 'Save'}
                  </button>
                  {ch.min_pct > 0 && <span className="text-[11px] text-slate-600">At least {ch.min_pct}% (already sold there).</span>}
                </div>
                <table className="w-full text-[11px] text-slate-700">
                  <thead><tr className="text-left text-slate-500"><th>Ticket type</th><th>Capacity</th><th>Seats at this share</th><th>Sold there</th></tr></thead>
                  <tbody>
                    {ch.tiers.map((t) => (
                      <tr key={t.tier_id}>
                        <td>{t.name}</td>
                        <td>{t.capacity ?? '—'}</td>
                        <td>{t.skip ? <span className="text-slate-500">{t.skip}</span> : seatsFor(t.capacity, pct)}</td>
                        <td>{t.sold}{t.sold > 0 && minPctFor(t.capacity, t.sold) > 0 ? ` (${minPctFor(t.capacity, t.sold)}%)` : ''}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </li>
            );
          })}
        </ul>
      )}

      {error && <p role="alert" className="text-[11px] text-rose-800">{error}</p>}
      {saved && <p role="status" className="text-[11px] text-emerald-800">{saved}</p>}

      <button type="button" onClick={() => void preview()} disabled={busy !== null || !view}
        className="rounded-lg border border-slate-300 text-xs font-bold px-3 py-2 disabled:opacity-50">
        {busy === 'preview' ? 'Planning…' : 'Preview what Exos would send'}
      </button>
      {plan && (
        <div data-testid="byo-plan" className="space-y-3">
          {plan.length === 0 && <p className="text-[11px] text-slate-600">No marketplace has a share above 0% yet.</p>}
          {plan.map((p) => (
            <div key={p.channel} className="space-y-1">
              <p className="text-xs font-bold text-slate-900">
                {p.label}: {p.steps.length} request{p.steps.length === 1 ? '' : 's'} planned; nothing sent.
              </p>
              {p.result.warnings.map((w) => <p key={w} className="text-[11px] text-amber-900">{w}</p>)}
              <ul className="space-y-1">
                {p.steps.map((s, i) => (
                  <li key={`${s.path}-${i}`}>
                    <details>
                      <summary className="text-[11px] font-mono text-slate-700">{s.method} {s.path}</summary>
                      <pre className="text-[10px] bg-slate-50 rounded p-2 overflow-x-auto">{JSON.stringify(s.body, null, 2)}</pre>
                    </details>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
