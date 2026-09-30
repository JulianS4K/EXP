// Hashed customer-list export for custom audiences (docs/marketing-catalog.md →
// "Audience export"). exos_org_audience_export (mig 20260930101000) returns
// SHA-256 hashes of consenting buyers only; this panel lays them out in the
// platform's upload format and saves the CSV. Owners and managers only (the
// RPC enforces it too); each export is logged.

import { useEffect, useState } from 'react';
import { Download } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { listOrgEvents } from '../lib/events';
import { useToast } from '../context/ToastContext';
import {
  AUDIENCE_PLATFORMS,
  audienceCsv,
  audienceFilename,
  parseAudienceExport,
  type AudiencePlatform,
} from '../lib/audienceCsv';
import type { Event } from '../types';

const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2';
const FLD =
  'w-full bg-white border border-slate-200 rounded-lg px-4 py-3 text-sm text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-tm-blue transition-colors disabled:opacity-60 disabled:bg-slate-50';

function saveCsv(csv: string, filename: string) {
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  const href = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = href;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(href), 0);
}

export default function AudienceExportPanel({ orgId, orgSlug }: { orgId: string; orgSlug: string }) {
  const { toast } = useToast();
  const [events, setEvents] = useState<Event[]>([]);
  const [eventId, setEventId] = useState('');
  const [platform, setPlatform] = useState<AudiencePlatform>('meta');
  const [busy, setBusy] = useState(false);
  const [last, setLast] = useState<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    listOrgEvents(orgId)
      .then((rows) => { if (!cancelled) setEvents(rows); })
      .catch(() => { /* the org-wide export still works */ });
    return () => { cancelled = true; };
  }, [orgId]);

  const run = async () => {
    setBusy(true);
    try {
      const { data, error } = await supabase.rpc('exos_org_audience_export', {
        p_org_id: orgId,
        p_event_id: eventId || null,
      });
      if (error) throw error;
      const out = parseAudienceExport(data);
      const ev = events.find((e) => e.id === eventId);
      saveCsv(audienceCsv(out.rows, platform), audienceFilename(orgSlug, platform, new Date(), ev ? (ev.slug || ev.title) : null));
      setLast(out.count);
      toast({ kind: 'success', message: `Exported ${out.count} ${out.count === 1 ? 'person' : 'people'}.` });
    } catch (e) {
      const msg = e instanceof Error ? e.message : (e as { message?: string })?.message;
      toast({ kind: 'error', message: msg?.replace(/^exos_org_audience_export: /, '') || 'Export failed.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8">
      <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest mb-2">Audience export</h2>
      <p className="text-xs text-slate-400 mb-4">
        A customer list for Meta, Google Customer Match or TikTok custom audiences. The file holds
        only SHA-256 hashes of email (and phone, when an account has one), never the addresses.
      </p>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-4">
        <label className="block">
          <span className={LBL}>Platform</span>
          <select className={FLD} value={platform} onChange={(e) => setPlatform(e.target.value as AudiencePlatform)} disabled={busy}>
            {AUDIENCE_PLATFORMS.map((p) => (
              <option key={p.id} value={p.id}>{p.label}</option>
            ))}
          </select>
        </label>
        <label className="block">
          <span className={LBL}>Buyers of</span>
          <select className={FLD} value={eventId} onChange={(e) => setEventId(e.target.value)} disabled={busy}>
            <option value="">All events</option>
            {events.map((e) => (
              <option key={e.id} value={e.id}>{e.title}</option>
            ))}
          </select>
        </label>
      </div>
      <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 mb-4 text-[11px] text-amber-800">
        <strong>Consent.</strong> Only buyers who allowed advertising at checkout are included
        (following you isn't enough). Anyone whose latest choice was no, who
        unsubscribed from marketing email, or who deleted their account is left out. Upload the
        file only to your own ad accounts, and keep your privacy policy saying you share hashed
        contact details with ad platforms. Each export is logged.
      </div>
      <button
        type="button"
        onClick={run}
        disabled={busy}
        className="px-4 py-2 bg-tm-blue text-white rounded text-[10px] font-black uppercase tracking-widest hover:opacity-90 disabled:opacity-60 inline-flex items-center gap-2"
      >
        <Download className="w-3 h-3" aria-hidden="true" />
        {busy ? 'Exporting…' : 'Download CSV'}
      </button>
      {last !== null && (
        <p className="text-[11px] text-slate-400 mt-3">
          Last export: {last} {last === 1 ? 'person' : 'people'}. Platforms need a minimum list size to
          serve ads (for example, TikTok asks for 1,000).
        </p>
      )}
    </div>
  );
}
