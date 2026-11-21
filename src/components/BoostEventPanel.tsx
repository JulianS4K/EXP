// Edit event → "Boost this event" (ads phase, mig 20261121190500): plan a
// paid campaign for the event on Meta and Reddit from one shared plan, and
// see exactly what Exos would send. A DRY RUN: nothing goes to an ad
// platform, every campaign / ad set / ad would be created paused, and the
// plan is also listed under "What we'd send" in Org settings. The price is a
// config value that is $0 for now; the daily budget defaults to $0.
// Owner / manager (exos-ads refuses anyone else).

import { useState } from 'react';
import { Megaphone } from 'lucide-react';
import {
  CAMPAIGN_CHANNELS, adsChannelLabel, budgetCents, geoLine, money, pausedSummary, planBoost,
  type BoostPlanResponse, type CampaignChannel,
} from '../lib/adsPlan';
import { stepLabel } from '../lib/channelAudit';

export default function BoostEventPanel({ eventId, orgId }: { eventId: string; orgId: string }) {
  const [channels, setChannels] = useState<CampaignChannel[]>(['meta_ads', 'reddit_ads']);
  const [budget, setBudget] = useState('0');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [plan, setPlan] = useState<BoostPlanResponse | null>(null);
  const [open, setOpen] = useState<string | null>(null);

  const toggle = (id: CampaignChannel) =>
    setChannels((c) => (c.includes(id) ? c.filter((x) => x !== id) : [...c, id]));

  const run = async () => {
    setBusy(true);
    setError(null);
    try {
      setPlan(await planBoost(orgId, eventId, channels, budgetCents(budget)));
    } catch (e) {
      setPlan(null);
      setError(e instanceof Error ? e.message : 'Planning failed.');
    } finally {
      setBusy(false);
    }
  };

  const p = plan?.plan;
  return (
    <section data-testid="boost-event-panel" aria-labelledby="boost-title"
      className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-4">
      <div className="flex items-center gap-2">
        <Megaphone className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h2 id="boost-title" className="text-sm font-black text-slate-900 uppercase tracking-widest">Boost this event</h2>
      </div>
      <p className="text-xs text-slate-600">
        Plan ads for this event on Meta and Reddit. This is a preview: Exos sends nothing to the ad platforms yet, and
        every campaign would be created paused. Boosting is free for now.
      </p>

      <fieldset className="space-y-2">
        <legend className="text-[11px] font-bold text-slate-700">Platforms</legend>
        {CAMPAIGN_CHANNELS.map((c) => (
          <label key={c.id} className="flex items-center gap-2 text-xs text-slate-800">
            <input type="checkbox" checked={channels.includes(c.id)} onChange={() => toggle(c.id)} />
            {c.label}
          </label>
        ))}
      </fieldset>
      <div className="space-y-1">
        <label htmlFor="boost-budget" className="block text-[11px] font-bold text-slate-700">Daily budget (USD)</label>
        <input id="boost-budget" inputMode="decimal" value={budget} onChange={(e) => setBudget(e.target.value)}
          className="w-32 border border-slate-300 rounded px-2 py-1 text-xs" />
      </div>
      <button type="button" disabled={busy || channels.length === 0} onClick={run}
        className="text-xs font-bold bg-slate-900 text-white rounded-lg px-3 py-2 disabled:opacity-50">
        {busy ? 'Planning…' : 'Plan the campaign'}
      </button>

      <div aria-live="polite">
        {error && <p role="alert" className="text-[11px] text-rose-800">{error}</p>}
        {p && plan && (
          <div data-testid="boost-plan" className="space-y-3">
            <p className="text-[11px] font-bold text-emerald-800">Dry run: nothing was sent.</p>
            <dl className="grid grid-cols-[auto,1fr] gap-x-3 gap-y-1 text-[11px] text-slate-800">
              <dt className="font-bold">Campaign</dt><dd>{p.name}</dd>
              <dt className="font-bold">Headline</dt><dd>{p.headline}</dd>
              <dt className="font-bold">Text</dt><dd>{p.body}</dd>
              <dt className="font-bold">Button</dt><dd>Buy tickets</dd>
              <dt className="font-bold">Daily budget</dt><dd>{money(p.dailyBudgetCents, p.currency)}</dd>
              <dt className="font-bold">Exos price</dt><dd>{p.priceCents === 0 ? 'Free' : money(p.priceCents)}</dd>
              <dt className="font-bold">Where</dt><dd>{geoLine(p.geo)}</dd>
              {p.communities.length > 0 && (<><dt className="font-bold">Communities</dt><dd>{p.communities.map((c) => `r/${c}`).join(', ')}</dd></>)}
            </dl>
            {p.blocked && <p role="note" className="text-[11px] text-rose-800 bg-rose-50 rounded px-2 py-1">{p.blocked}</p>}
            {plan.channels.map((c) => (
              <div key={c.channel} data-testid="boost-channel" className="border border-slate-200 rounded-lg p-3 space-y-1">
                <h3 className="text-xs font-black text-slate-700 uppercase tracking-widest">{adsChannelLabel(c.channel)}</h3>
                <p className="text-[11px] text-slate-700">{pausedSummary(c.result)}</p>
                {[...new Set(c.result.warnings)].map((w) => (
                  <p key={w} role="note" className="text-[11px] text-amber-800 bg-amber-50 rounded px-2 py-1">{w}</p>
                ))}
                <ol className="space-y-1">
                  {c.steps.map((s, i) => {
                    const id = `boost-${c.channel}-${i}`;
                    return (
                      <li key={id} className="text-[11px]">
                        <span className="font-mono font-bold">{s.method}</span>{' '}
                        <span className="font-mono break-all">{s.path}</span>{' '}
                        <span className="text-slate-600">{stepLabel(s.op)}</span>
                        {s.error && <span className="text-rose-800"> ({s.error})</span>}
                        <button type="button" className="ml-2 underline font-bold text-slate-700"
                          aria-expanded={open === id} aria-controls={id} onClick={() => setOpen(open === id ? null : id)}>
                          {open === id ? 'Hide' : 'Payload'}
                        </button>
                        {open === id && (
                          <pre id={id} className="text-[10px] bg-slate-50 border border-slate-200 rounded p-2 whitespace-pre-wrap break-all">
                            {JSON.stringify(s.body, null, 2)}
                          </pre>
                        )}
                      </li>
                    );
                  })}
                </ol>
              </div>
            ))}
            <p className="text-[11px] text-slate-600">The same steps are listed under What we&apos;d send in Org settings.</p>
          </div>
        )}
      </div>
    </section>
  );
}
