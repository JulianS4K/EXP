// Org settings → "Ad audiences" (ads phase, mig 20261121190500): plan an
// audience of the org's fans and buyers who agreed to advertising, for Meta,
// Google Customer Match or Reddit. Only hashes would be uploaded, and a DRY
// RUN: nothing is sent, the plan is listed under "What we'd send".
// Owner / manager.

import { useState } from 'react';
import { Users } from 'lucide-react';
import { AUDIENCE_CHANNELS, adsChannelLabel, planAudience, type AudienceChannel, type AudiencePlanResponse } from '../lib/adsPlan';
import { stepLabel } from '../lib/channelAudit';

export default function AdAudienceSyncPanel({ orgId }: { orgId: string }) {
  const [channel, setChannel] = useState<AudienceChannel>('meta_ads');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [out, setOut] = useState<AudiencePlanResponse | null>(null);

  const run = async () => {
    setBusy(true);
    setError(null);
    try {
      setOut(await planAudience(orgId, channel));
    } catch (e) {
      setOut(null);
      setError(e instanceof Error ? e.message : 'Planning failed.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <section data-testid="ad-audience-panel" aria-labelledby="ad-audience-title"
      className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-4">
      <div className="flex items-center gap-2">
        <Users className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h2 id="ad-audience-title" className="text-sm font-black text-slate-900 uppercase tracking-widest">Ad audiences</h2>
      </div>
      <p className="text-xs text-slate-600">
        An audience of your fans and buyers who agreed to advertising at checkout, hashed before it leaves Exos. This is
        a preview: nothing is uploaded yet.
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <div className="space-y-1">
          <label htmlFor="ad-audience-channel" className="block text-[11px] font-bold text-slate-700">Platform</label>
          <select id="ad-audience-channel" value={channel} onChange={(e) => setChannel(e.target.value as AudienceChannel)}
            className="border border-slate-300 rounded px-2 py-1 text-xs">
            {AUDIENCE_CHANNELS.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
          </select>
        </div>
        <button type="button" disabled={busy} onClick={run}
          className="text-xs font-bold bg-slate-900 text-white rounded-lg px-3 py-2 disabled:opacity-50">
          {busy ? 'Planning…' : 'Plan the audience'}
        </button>
      </div>
      <div aria-live="polite">
        {error && <p role="alert" className="text-[11px] text-rose-800">{error}</p>}
        {out && (
          <div data-testid="ad-audience-plan" className="space-y-2">
            <p className="text-[11px] font-bold text-emerald-800">Dry run: nothing was sent.</p>
            <p className="text-[11px] text-slate-800">
              {adsChannelLabel(out.channel)}: {out.audience.members} {out.audience.members === 1 ? 'person' : 'people'} who agreed to
              advertising ({out.audience.withEmail} with an email, {out.audience.withPhone} with a phone).
            </p>
            {[...new Set(out.result.warnings)].map((w) => (
              <p key={w} role="note" className="text-[11px] text-amber-800 bg-amber-50 rounded px-2 py-1">{w}</p>
            ))}
            {out.result.stopped && <p className="text-[11px] text-slate-700">{out.result.stopped}</p>}
            <ol className="space-y-1">
              {out.steps.map((s, i) => (
                <li key={i} className="text-[11px]">
                  <span className="font-mono font-bold">{s.method}</span> <span className="font-mono break-all">{s.path}</span>{' '}
                  <span className="text-slate-600">{stepLabel(s.op)}</span>
                </li>
              ))}
            </ol>
          </div>
        )}
      </div>
    </section>
  );
}
