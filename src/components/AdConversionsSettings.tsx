// "Ads & conversions" in org settings: per-platform ids, a write-only access
// token, an on/off switch and a test code for server-side conversions
// (mig 20260930100000, exos-conversions-drain, docs/marketing-conversions.md).
// Owner / manager only; the RPCs enforce it too. The token is never read
// back: a saved one shows as "•••• saved" and a blank field keeps it.

import { useEffect, useState } from 'react';
import { useToast } from '../context/ToastContext';
import {
  AD_PLATFORMS, type AdCredential, type AdPlatform, type AdPlatformInfo, TEST_CODE_RE,
  listAdCredentials, saveAdCredential, validateAdConfig,
} from '../lib/adCredentials';

const LBL = 'text-[10px] text-slate-400 uppercase tracking-widest';
const FLD =
  'w-full bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-tm-blue transition-colors disabled:opacity-60 disabled:bg-slate-50';

interface Draft {
  config: Record<string, string>;
  secret: string;
  removeSecret: boolean;
  enabled: boolean;
  testEventCode: string;
}

const draftFrom = (c: AdCredential | undefined): Draft => ({
  config: { ...(c?.config ?? {}) },
  secret: '',
  removeSecret: false,
  enabled: c?.enabled ?? false,
  testEventCode: c?.testEventCode ?? '',
});

export default function AdConversionsSettings({ orgId, canEdit }: { orgId: string; canEdit: boolean }) {
  const { toast } = useToast();
  const [saved, setSaved] = useState<Record<string, AdCredential>>({});
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [open, setOpen] = useState<AdPlatform | null>(null);
  const [busy, setBusy] = useState<AdPlatform | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  const reload = async () => {
    try {
      const rows = await listAdCredentials(orgId);
      const byId: Record<string, AdCredential> = {};
      for (const r of rows) byId[r.platform] = r;
      setSaved(byId);
      setDrafts(Object.fromEntries(AD_PLATFORMS.map((p) => [p.id, draftFrom(byId[p.id])])));
      setLoadError(null);
    } catch (e: any) {
      setLoadError(e?.code === '42501' ? 'Only owners and managers can see ad connections.' : 'Could not load ad connections.');
    }
  };
  useEffect(() => { reload(); /* eslint-disable-next-line */ }, [orgId]);

  const patch = (id: AdPlatform, p: Partial<Draft>) =>
    setDrafts((d) => ({ ...d, [id]: { ...(d[id] ?? draftFrom(undefined)), ...p } }));

  const save = async (info: AdPlatformInfo) => {
    const d = drafts[info.id] ?? draftFrom(undefined);
    const errs = validateAdConfig(info, d.config, d.enabled);
    const firstErr = Object.entries(errs)[0];
    if (firstErr) {
      toast({ kind: 'error', message: `${info.fields.find((f) => f.key === firstErr[0])?.label}: ${firstErr[1]}` });
      return;
    }
    const willHaveSecret = !d.removeSecret && (!!d.secret.trim() || !!saved[info.id]?.hasSecret);
    if (d.enabled && !willHaveSecret) {
      toast({ kind: 'error', message: `Add the ${info.secretLabel.toLowerCase()} to turn ${info.label} on.` });
      return;
    }
    if (d.testEventCode.trim() && !TEST_CODE_RE.test(d.testEventCode.trim())) {
      toast({ kind: 'error', message: 'Test code: letters, digits, _ and - only.' });
      return;
    }
    setBusy(info.id);
    try {
      const config: Record<string, string> = {};
      for (const f of info.fields) {
        const v = (d.config[f.key] ?? '').trim();
        if (v) config[f.key] = v;
      }
      await saveAdCredential(orgId, info.id, {
        config,
        secret: d.secret,
        removeSecret: d.removeSecret,
        enabled: d.enabled && willHaveSecret,
        testEventCode: d.testEventCode,
      });
      toast({ kind: 'success', message: `${info.label} saved.` });
      await reload();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message?.replace(/^exos_set_ad_credential: /, '') || 'Could not save.' });
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8">
      <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest mb-2">Ads &amp; conversions</h2>
      <p className="text-xs text-slate-400 mb-5">
        Report paid orders to your ad accounts from our server, so purchases count even when a
        browser blocks the pixel. Sent only for buyers who accepted marketing cookies, with the
        email hashed. The same order id as the pixel is used, so nothing is counted twice.
        Tokens are stored encrypted and can't be read back.
      </p>
      {loadError ? (
        <p className="text-xs text-slate-500">{loadError}</p>
      ) : (
        <ul className="divide-y divide-slate-100 border border-slate-200 rounded-xl">
          {AD_PLATFORMS.map((info) => {
            const s = saved[info.id];
            const d = drafts[info.id] ?? draftFrom(s);
            const isOpen = open === info.id;
            const status = s?.enabled ? (info.plannedOnly ? 'On (not sending yet)' : 'On') : s ? 'Off' : 'Not set up';
            return (
              <li key={info.id}>
                <button
                  type="button"
                  onClick={() => setOpen(isOpen ? null : info.id)}
                  aria-expanded={isOpen}
                  className="w-full flex items-center justify-between gap-3 px-4 py-3 text-left hover:bg-slate-50"
                >
                  <span className="text-sm font-bold text-slate-900">{info.label}</span>
                  <span className={`text-[10px] font-black uppercase tracking-widest ${s?.enabled ? 'text-emerald-600' : 'text-slate-400'}`}>
                    {status}
                  </span>
                </button>
                {isOpen && (
                  <div className="px-4 pb-4 space-y-3">
                    <p className="text-xs text-slate-500">{info.help}</p>
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                      {info.fields.map((f) => (
                        <label key={f.key} className="block">
                          <span className={LBL}>{f.label}</span>
                          <input
                            type="text"
                            className={`${FLD} mt-1`}
                            value={d.config[f.key] ?? ''}
                            onChange={(e) => patch(info.id, { config: { ...d.config, [f.key]: e.target.value } })}
                            placeholder={f.placeholder}
                            disabled={!canEdit}
                            autoComplete="off"
                            spellCheck={false}
                          />
                        </label>
                      ))}
                      <label className="block">
                        <span className={LBL}>{info.secretLabel}</span>
                        <input
                          type="password"
                          className={`${FLD} mt-1`}
                          value={d.secret}
                          onChange={(e) => patch(info.id, { secret: e.target.value, removeSecret: false })}
                          placeholder={s?.hasSecret && !d.removeSecret ? '•••• saved' : 'Paste the token'}
                          disabled={!canEdit}
                          autoComplete="new-password"
                          spellCheck={false}
                        />
                        {s?.hasSecret && canEdit && (
                          <button
                            type="button"
                            onClick={() => patch(info.id, { removeSecret: !d.removeSecret, secret: '', enabled: d.removeSecret ? d.enabled : false })}
                            className="mt-1 text-[10px] font-black uppercase tracking-widest text-slate-400 hover:text-red-600"
                          >
                            {d.removeSecret ? 'Keep the saved token' : 'Remove the saved token'}
                          </button>
                        )}
                      </label>
                      {info.testLabel && (
                        <label className="block">
                          <span className={LBL}>{info.testLabel}</span>
                          <input
                            type="text"
                            className={`${FLD} mt-1`}
                            value={d.testEventCode}
                            onChange={(e) => patch(info.id, { testEventCode: e.target.value })}
                            placeholder="Leave empty for live events"
                            disabled={!canEdit}
                            autoComplete="off"
                          />
                        </label>
                      )}
                    </div>
                    <label className="flex items-center gap-2 text-xs text-slate-600">
                      <input
                        type="checkbox"
                        checked={d.enabled}
                        onChange={(e) => patch(info.id, { enabled: e.target.checked })}
                        disabled={!canEdit}
                      />
                      Send purchases{info.id === 'ga4' ? ' and refunds' : ''} to {info.label}
                    </label>
                    {s && (
                      <p className="text-[11px] text-slate-400">
                        Last 30 days: {s.sent30d} sent, {s.pending} waiting, {s.skipped30d} skipped, {s.failed30d} failed
                        {s.lastSentAt ? ` · last sent ${new Date(s.lastSentAt).toLocaleString()}` : ''}
                      </p>
                    )}
                    {canEdit && (
                      <button
                        type="button"
                        onClick={() => save(info)}
                        disabled={busy !== null}
                        className="px-4 py-2 bg-slate-900 text-white rounded text-[10px] font-black uppercase tracking-widest hover:bg-slate-700 transition-colors disabled:opacity-50"
                      >
                        {busy === info.id ? 'Saving…' : 'Save'}
                      </button>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
