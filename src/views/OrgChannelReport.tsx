// /orgs/:orgId/channels — the org's weekly channel report (mig 20261029120000):
// what the Monday email says, on screen, for the last full week or an earlier
// one, plus the report's settings. Owner / manager / finance read; the owner
// turns it on / off and sets the number for the weekly text.

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Share2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { canSeeMoney } from '../lib/settlement';
import {
  getChannelReportSettings, getOrgChannelReport, setChannelReport, type ChannelReportSettings,
} from '../lib/channelReportApi';
import { notReportedNote, totalsText, weekLabel, type ChannelReport } from '../../supabase/functions/_shared/channelReport.ts';
import { ChannelNotes, ChannelTable } from '../components/ChannelSalesPanel';

const LBL = 'block text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1';
const FLD = 'w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

/** Monday (UTC, yyyy-mm-dd) of the week `weeksBack` full weeks ago. */
function mondayIso(weeksBack: number): string {
  const d = new Date();
  const day = (d.getUTCDay() + 6) % 7; // Monday = 0
  d.setUTCHours(0, 0, 0, 0);
  d.setUTCDate(d.getUTCDate() - day - 7 * weeksBack);
  return d.toISOString().slice(0, 10);
}

function SettingsCard({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [s, setS] = useState<ChannelReportSettings | null>(null);
  const [phone, setPhone] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    void getChannelReportSettings(orgId).then(setS);
  }, [orgId]);
  if (!s) return null;

  const save = async (enabled: boolean, smsPhone: string | null) => {
    setBusy(true);
    try {
      setS(await setChannelReport(orgId, enabled, smsPhone));
      setPhone('');
      toast({ kind: 'success', message: 'Saved.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8" aria-labelledby="report-settings">
      <h2 id="report-settings" className="text-sm font-bold text-slate-700 mb-1">Monday email</h2>
      <p className="text-xs text-slate-500 mb-4">
        Every Monday the owner and managers get last week's tickets by channel, and the totals to date, for events
        from the last week and the next 60 days. Each person can unsubscribe from the email's footer.
        {s.lastWeek ? ` Last sent: ${s.lastWeek}.` : ''}
      </p>
      <label className="inline-flex items-center gap-2 text-sm text-slate-700 mb-4">
        <input type="checkbox" checked={s.enabled} disabled={!s.canEdit || busy}
          onChange={(e) => void save(e.target.checked, null)} />
        Send the weekly channel report
      </label>
      <div className="border-t border-slate-100 pt-4">
        <h3 className="text-xs font-bold text-slate-700 mb-1">Weekly text (optional)</h3>
        {!s.smsProvider ? (
          <p className="text-xs text-slate-500">Connect Twilio or Telnyx in Integrations to also get a short weekly text from your own number.</p>
        ) : (
          <>
            <p className="text-xs text-slate-500 mb-3">
              A short summary with a link to this page, sent from your {s.smsProvider === 'twilio' ? 'Twilio' : 'Telnyx'} number
              between 9am and 8pm New York time. Reply STOP to turn it off.
              {s.smsPhoneHint ? ` Goes to the number ending ${s.smsPhoneHint.replace('…', '')}.` : ' Off.'}
            </p>
            {s.canEdit && (
              <div className="flex flex-wrap items-end gap-2">
                <label className="block flex-1 min-w-[12rem]"><span className={LBL}>Mobile number</span>
                  <input className={FLD} value={phone} inputMode="tel" onChange={(e) => setPhone(e.target.value)} placeholder="+1 212 555 0100" /></label>
                <button type="button" disabled={busy || !phone.trim()} onClick={() => void save(s.enabled, phone)}
                  className="px-4 py-2 bg-tm-blue text-white rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
                  Save number
                </button>
                {s.smsPhoneHint && (
                  <button type="button" disabled={busy} onClick={() => void save(s.enabled, '')}
                    className="px-4 py-2 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600">
                    Stop texts
                  </button>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </section>
  );
}

export default function OrgChannelReport() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { orgs, loading: orgsLoading } = useOrganization();
  const entry = orgs.find((o) => o.org.id === orgId);
  const allowed = canSeeMoney(entry?.membership.role, isAdmin);
  const [weeksBack, setWeeksBack] = useState(1);
  // undefined = loading, null = unavailable.
  const [rep, setRep] = useState<ChannelReport | null | undefined>(undefined);

  useEffect(() => {
    if (!orgId || !allowed) return undefined;
    let cancelled = false;
    setRep(undefined);
    void getOrgChannelReport(orgId, mondayIso(weeksBack)).then((r) => {
      if (!cancelled) setRep(r);
    });
    return () => {
      cancelled = true;
    };
  }, [orgId, allowed, weeksBack]);

  if (!user) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 font-bold uppercase tracking-widest">Sign in required.</div>;
  }
  if (!orgsLoading && !allowed) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 text-sm">The channel report is visible to the org's owners, managers and finance team.</div>;
  }
  const note = rep ? notReportedNote(rep.totals.toDate) : '';

  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-5xl mx-auto px-4 py-10">
        <Link to="/dashboard" className="inline-flex items-center gap-1 text-xs font-bold text-slate-500 hover:text-slate-800 mb-6">
          <ArrowLeft className="w-3 h-3" aria-hidden="true" /> Dashboard
        </Link>
        <div className="flex flex-wrap items-end justify-between gap-3 mb-6">
          <div>
            <h1 className="text-2xl font-black flex items-center gap-2"><Share2 className="w-5 h-5" aria-hidden="true" /> Channels</h1>
            <p className="text-sm text-slate-500">{entry?.org.name ?? ''}: tickets by where they sold, by week.</p>
          </div>
          <label className="text-[10px] font-black uppercase tracking-widest text-slate-400">
            <span className="sr-only">Week</span>
            <select value={weeksBack} onChange={(e) => setWeeksBack(Number(e.target.value))}
              className="px-2 py-2 rounded border border-slate-200 text-[10px] font-black uppercase tracking-widest text-slate-600 bg-white">
              <option value={0}>This week so far</option>
              {[1, 2, 3, 4, 5, 6, 7, 8].map((w) => (
                <option key={w} value={w}>{w === 1 ? 'Last week' : `${w} weeks ago`}</option>
              ))}
            </select>
          </label>
        </div>

        {orgId && <SettingsCard orgId={orgId} />}

        {rep === undefined && <p className="text-sm text-slate-400">Loading…</p>}
        {rep === null && <p className="text-sm text-slate-400">The channel report isn't available yet.</p>}
        {rep && (
          <>
            <section className="bg-white rounded-2xl p-6 shadow-sm mb-8">
              <h2 className="text-sm font-bold text-slate-700 mb-2">{weekLabel(rep.from, rep.to)} (UTC)</h2>
              <p className="text-sm text-slate-700"><span className="font-bold">This week:</span> {totalsText(rep.totals.week)}</p>
              <p className="text-sm text-slate-700"><span className="font-bold">To date:</span> {totalsText(rep.totals.toDate)}</p>
              {note && <p className="text-xs text-amber-700 mt-2">{note}</p>}
              {rep.events.length === 0 && <p className="text-xs text-slate-400 mt-2">No events from the last week or the next 60 days.</p>}
            </section>
            {rep.events.map((e) => (
              <section key={e.id} className="bg-white rounded-2xl p-6 shadow-sm mb-6">
                <div className="flex flex-wrap items-baseline justify-between gap-2 mb-3">
                  <Link to={`/dashboard/event/${e.id}`} className="text-sm font-bold text-slate-800 hover:underline">{e.name}</Link>
                  {e.startsAt && <span className="text-[11px] text-slate-500">{new Date(e.startsAt).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short', timeZone: e.timezone || undefined })}</span>}
                </div>
                <ChannelTable e={e} />
                <ChannelNotes e={e} />
              </section>
            ))}
            {rep.moreEvents > 0 && <p className="text-xs text-slate-500">And {rep.moreEvents} more event{rep.moreEvents === 1 ? '' : 's'} (see each event's report).</p>}
          </>
        )}
      </div>
    </div>
  );
}
