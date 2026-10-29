// Org settings → Integrations (mig 20261016090000): the org's own accounts
// for ticket backends (pretix, hi.events, Luma), SMS (Twilio, Telnyx) and resale
// marketplaces. Secrets are pasted once and never shown again.

import { Fragment, useCallback, useEffect, useState } from 'react';
import { CheckCircle2, AlertTriangle, Plug } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import EventbriteConnect from './EventbriteConnect';
import {
  PROVIDERS, cleanConfig, configError, listIntegrations, removeIntegration, saveIntegration, testIntegration,
  type IntegrationRow, type ProviderGroup, type ProviderInfo,
} from '../lib/integrations';

const GROUPS: { id: ProviderGroup; label: string; note: string }[] = [
  { id: 'backend', label: 'Ticket backends', note: 'Sell on another platform; Exos runs the page, marketing and the door. Each event links to its Eventbrite event on its door tab.' },
  { id: 'sms', label: 'SMS', note: 'Text fans who opted in, from your own number.' },
  { id: 'marketplace', label: 'Resale marketplaces', note: 'Your own seller accounts, for reads. Exos never changes prices or inventory there.' },
];

const LBL = 'block text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1';
const FLD = 'w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
const BTN = 'px-3 py-1.5 rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50';

function ProviderCard({ p, row, orgId, canEdit, onChanged }: {
  p: ProviderInfo; row: IntegrationRow | undefined; orgId: string; canEdit: boolean; onChanged: () => void;
}) {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [config, setConfig] = useState<Record<string, string>>({});
  const [secret, setSecret] = useState('');
  const [busy, setBusy] = useState(false);

  const start = () => {
    setConfig(Object.fromEntries(p.fields.map((f) => [f.key, row?.config[f.key] ?? f.defaultValue ?? ''])));
    setSecret('');
    setOpen(true);
  };
  const err = open ? configError(p, config, secret, row?.hasSecret === true) : null;

  const test = async () => {
    setBusy(true);
    try {
      const r = await testIntegration(orgId, p.id);
      if (r.ok === true) toast({ kind: 'success', message: `Connected${r.account_name ? `: ${r.account_name}` : ''}.` });
      else if (r.ok === false) toast({ kind: 'error', message: r.error || 'The test failed.' });
      else toast({ kind: 'info', message: 'Saved. Exos only reads this account when a feature needs it.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
      onChanged();
    }
  };

  const save = async () => {
    if (err) return;
    setBusy(true);
    try {
      await saveIntegration(orgId, p.id, cleanConfig(p, config), secret);
      setOpen(false);
      setSecret('');
      onChanged();
      await test();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!window.confirm(`Disconnect ${p.label}? The saved ${p.secretLabel?.toLowerCase() ?? 'settings'} are deleted.`)) return;
    setBusy(true);
    try {
      await removeIntegration(orgId, p.id);
      onChanged();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const status = row?.status;
  return (
    <li className="border border-slate-200 rounded-xl p-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="text-sm font-bold text-slate-900">{p.label}</p>
          <p className="text-[11px] text-slate-500 mt-0.5">{p.blurb}</p>
        </div>
        {row && (
          <span className={`inline-flex items-center gap-1 text-[10px] font-black uppercase tracking-widest rounded px-2 py-0.5 ${
            status === 'connected' ? 'bg-emerald-50 text-emerald-700' : status === 'error' ? 'bg-rose-50 text-rose-700' : 'bg-slate-100 text-slate-600'}`}>
            {status === 'connected' ? <CheckCircle2 className="w-3 h-3" aria-hidden="true" /> : status === 'error' ? <AlertTriangle className="w-3 h-3" aria-hidden="true" /> : null}
            {status === 'connected' ? 'Connected' : status === 'error' ? 'Error' : 'Saved'}
          </span>
        )}
      </div>
      {row && !open && (
        <p className="text-[11px] text-slate-500 mt-2">
          {row.accountName ? `${row.accountName} · ` : ''}
          {p.fields.map((f) => row.config[f.key]).filter(Boolean).join(' · ')}
          {row.secretHint ? ` · ${p.secretLabel} ${row.secretHint}` : ''}
          {row.lastError ? <span className="block text-rose-600 mt-1">{row.lastError}</span> : null}
        </p>
      )}
      {open && (
        <div className="mt-3 space-y-3">
          {p.fields.map((f) => (
            <label key={f.key} className="block">
              <span className={LBL}>{f.label}</span>
              <input className={FLD} value={config[f.key] ?? ''} placeholder={f.placeholder} autoComplete="off"
                onChange={(e) => setConfig((c) => ({ ...c, [f.key]: e.target.value }))} />
              {f.help && <span className="block text-[11px] text-slate-400 mt-1">{f.help}</span>}
            </label>
          ))}
          {p.secretLabel && (
            <label className="block">
              <span className={LBL}>{p.secretLabel}{row?.hasSecret ? ` (saved ${row.secretHint ?? ''}; leave empty to keep)` : ''}</span>
              <input className={FLD} type="password" value={secret} autoComplete="new-password" spellCheck={false}
                onChange={(e) => setSecret(e.target.value)} />
              {p.secretHelp && <span className="block text-[11px] text-slate-400 mt-1">{p.secretHelp}</span>}
            </label>
          )}
          {err && <p className="text-[11px] text-rose-600">{err}</p>}
          <div className="flex gap-2">
            <button type="button" onClick={() => void save()} disabled={busy || !!err} className={`${BTN} bg-tm-blue text-white`}>
              {busy ? 'Saving…' : 'Save and test'}
            </button>
            <button type="button" onClick={() => setOpen(false)} className={`${BTN} border border-slate-200 text-slate-600`}>Cancel</button>
          </div>
        </div>
      )}
      {canEdit && !open && (
        <div className="mt-3 flex flex-wrap gap-2">
          <button type="button" onClick={start} disabled={busy} className={`${BTN} border border-slate-200 text-slate-700`}>
            {row ? 'Edit' : 'Connect'}
          </button>
          {row && (
            <>
              <button type="button" onClick={() => void test()} disabled={busy} className={`${BTN} border border-slate-200 text-slate-700`}>Test</button>
              <button type="button" onClick={() => void remove()} disabled={busy} className={`${BTN} border border-rose-200 text-rose-600`}>Disconnect</button>
            </>
          )}
          {p.docsUrl && (
            <a href={p.docsUrl} target="_blank" rel="noreferrer noopener" className="text-[10px] font-black uppercase tracking-widest text-slate-400 hover:text-slate-700 self-center">
              Docs
            </a>
          )}
        </div>
      )}
    </li>
  );
}

export default function IntegrationsPanel({ orgId, canEdit }: { orgId: string; canEdit: boolean }) {
  const [rows, setRows] = useState<IntegrationRow[] | null>(null);
  const [failed, setFailed] = useState(false);
  const load = useCallback(() => {
    listIntegrations(orgId).then((r) => { setRows(r); setFailed(false); }).catch(() => setFailed(true));
  }, [orgId]);
  useEffect(load, [load]);

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8">
      <div className="flex items-center gap-2 mb-2">
        <Plug className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest">Integrations</h2>
      </div>
      <p className="text-xs text-slate-400 mb-5">
        Your own accounts. Tokens and keys are stored encrypted and can't be read back, only replaced.
      </p>
      {failed && <p className="text-xs text-slate-500 mb-4">Integrations aren't available yet on this install.</p>}
      {!failed && (
        <div className="space-y-6">
          {GROUPS.map((g) => (
            <section key={g.id}>
              <h3 className="text-[10px] font-black text-slate-500 uppercase tracking-widest">{g.label}</h3>
              <p className="text-[11px] text-slate-400 mb-2">{g.note}</p>
              <ul className="space-y-3">
                {g.id === 'backend' && <EventbriteConnect orgId={orgId} />}
                {PROVIDERS.filter((p) => p.group === g.id).map((p) => (
                  <Fragment key={p.id}>
                    <ProviderCard p={p} row={rows?.find((r) => r.provider === p.id)} orgId={orgId} canEdit={canEdit} onChanged={load} />
                  </Fragment>
                ))}
              </ul>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
