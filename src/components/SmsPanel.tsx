// Event report → Marketing → Text messages (mig 20261016120000). Owner /
// manager write a text to the org's list or this event's ticket holders who
// opted in; it goes out from the org's own Twilio / Telnyx number between
// 9:00 and 20:00, with the org's name and "Reply STOP to opt out" added.

import { useCallback, useEffect, useState } from 'react';
import { MessageSquare } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useToast } from '../context/ToastContext';
import { audienceSize, cancelCampaign, createCampaign, finalBody, segments, smsOverview, type SmsOverview } from '../lib/sms';

export default function SmsPanel({ orgId, orgName, eventId, canSend, canView }: {
  orgId: string; orgName: string; eventId: string; canSend: boolean; canView: boolean;
}) {
  const { toast } = useToast();
  const [ov, setOv] = useState<SmsOverview | null>(null);
  const [audience, setAudience] = useState<'event_buyers' | 'org'>('event_buyers');
  const [size, setSize] = useState<{ reachable: number; capped: number } | null>(null);
  const [body, setBody] = useState('');
  const [when, setWhen] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    if (!canView) return;
    smsOverview(orgId).then(setOv).catch(() => setOv(null));
  }, [orgId, canView]);
  useEffect(load, [load]);
  useEffect(() => {
    if (!canView) return;
    audienceSize(orgId, audience, eventId).then(setSize).catch(() => setSize(null));
  }, [orgId, audience, eventId, canView]);
  if (!canView || !ov) return null;

  const preview = finalBody(orgName, body || '…');
  const seg = segments(preview);

  const send = async () => {
    if (!window.confirm(`Text ${size?.reachable ?? 0} people? This can't be unsent once it goes out.`)) return;
    setBusy(true);
    try {
      const r = await createCampaign(orgId, body, audience, eventId, when ? new Date(when) : null);
      toast({ kind: 'success', message: `Queued for ${r.queued}${r.skippedCap ? ` (${r.skippedCap} skipped: texted 8 times this month)` : ''}. Goes out ${r.sendAfter.toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' })}.` });
      setBody(''); setWhen('');
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-8">
      <div className="flex items-center gap-2 mb-1">
        <MessageSquare className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h3 className="text-sm font-bold text-slate-700">Text messages</h3>
      </div>
      <p className="text-xs text-slate-500 mb-4">
        {ov.subscribers} people opted in to {orgName}'s texts ({ov.optedOut} stopped). Fans sign up from their ticket.
        Texts go out 9:00 to 20:00, at most 8 a month per person.
      </p>
      {!ov.provider ? (
        <p className="text-xs text-slate-500">
          Connect Twilio or Telnyx in <Link to={`/orgs/${orgId}/settings`} className="underline">Org settings → Integrations</Link> to send.
        </p>
      ) : canSend && (
        <div className="space-y-3 mb-5">
          <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Who gets it">
            {([['event_buyers', 'This event\'s ticket holders'], ['org', 'Everyone on the list']] as const).map(([v, l]) => (
              <button key={v} type="button" role="radio" aria-checked={audience === v} onClick={() => setAudience(v)}
                className={`px-3 py-1.5 rounded text-[10px] font-black uppercase tracking-widest border ${audience === v ? 'border-tm-blue text-tm-blue' : 'border-slate-200 text-slate-600'}`}>
                {l}
              </button>
            ))}
            {size && <span className="text-[11px] text-slate-500 self-center">{size.reachable} will get it{size.capped ? ` · ${size.capped} at the monthly limit` : ''}</span>}
          </div>
          <textarea value={body} maxLength={400} rows={3} onChange={(e) => setBody(e.target.value)}
            placeholder="Doors at 10. Show this text at the bar for a free drink before 11."
            className="w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800" aria-label="Message" />
          <p className="text-[11px] text-slate-500">
            Fans see: <span className="text-slate-700">{preview}</span>
            <span className="block mt-1">{seg.count} SMS segment{seg.count === 1 ? '' : 's'}{seg.unicode ? ' (emoji / accents make segments shorter)' : ''} each.</span>
          </p>
          <div className="flex flex-wrap items-end gap-3">
            <label className="block"><span className="block text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1">Send at (optional)</span>
              <input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)}
                className="bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800" /></label>
            <button type="button" onClick={() => void send()} disabled={busy || !body.trim() || !size?.reachable}
              className="px-4 py-2 bg-tm-blue text-white rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
              {busy ? 'Queuing…' : 'Send'}
            </button>
          </div>
        </div>
      )}
      {ov.campaigns.length > 0 && (
        <ul className="divide-y divide-slate-100 text-xs text-slate-600">
          {ov.campaigns.slice(0, 10).map((c) => (
            <li key={c.id} className="py-2">
              <p className="text-slate-800">{c.body}</p>
              <p className="text-[11px] text-slate-400 mt-0.5">
                {c.audience === 'org' ? 'Everyone' : 'Ticket holders'} · {c.status}
                {` · ${c.sent} sent`}{c.dryRun ? ` · ${c.dryRun} dry run (sending is off on this install)` : ''}{c.failed ? ` · ${c.failed} failed` : ''}
                {` · ${c.sendAfter.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}`}
                {canSend && (c.status === 'queued' || c.status === 'sending') && (
                  <button type="button" className="ml-2 underline" onClick={async () => {
                    const n = await cancelCampaign(c.id).catch(() => 0);
                    toast({ kind: 'success', message: `Cancelled ${n} not yet sent.` });
                    load();
                  }}>Cancel</button>
                )}
              </p>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
