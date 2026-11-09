// Org settings → Distribution partners (mig 20261031130000, docs/partner-sales.md).
// Owners mint one key per broker / marketplace that sells the org's tickets
// through the partner contract (shown once), pause, change or revoke it.
// Managers see the list (they pick partners per ticket type in the event
// editor). What a partner may sell is set per ticket type there.

import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Copy, EyeOff, Handshake, Plus, Trash2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  createDistributionPartner, listDistributionPartners, PARTNER_TYPE_LABEL, PARTNER_TYPES, revokeDistributionPartner,
  sqlMessage, updateDistributionPartner, type DistributionPartner,
} from '../lib/developerPlatform';

const BTN = 'text-[11px] font-black uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const FLD = 'bg-black border border-white/20 px-3 py-2 text-xs text-white';

export default function DistributionPartnersPanel({ orgId, canEdit }: { orgId: string; canEdit: boolean }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<DistributionPartner[] | null>(null);
  const [label, setLabel] = useState('');
  const [type, setType] = useState<string>('stubhub');
  const [comps, setComps] = useState(false);
  const [fresh, setFresh] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    listDistributionPartners(orgId).then(setRows).catch(() => setRows([]));
  }, [orgId]);
  useEffect(load, [load]);

  const run = async (fn: () => Promise<unknown>, ok?: string) => {
    setBusy(true);
    try {
      await fn();
      if (ok) toast({ kind: 'success', message: ok });
      load();
    } catch (e) {
      toast({ kind: 'error', message: sqlMessage(e) });
    } finally {
      setBusy(false);
    }
  };

  const live = (rows ?? []).filter((r) => !r.revoked_at);

  return (
    <fieldset className="bg-[#111] rounded-2xl border border-white/10 p-5 space-y-4">
      <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">Distribution partners</legend>
      <div className="flex items-start gap-2 text-white/40 text-xs">
        <Handshake className="w-4 h-4 text-brand-primary shrink-0" aria-hidden="true" />
        <p>
          Brokers and marketplaces that sell your tickets through the partner API (the contract they already use with
          Opendate). Each gets its own key. They can only sell ticket types you switch on for partners in the event
          editor; every ticket they sell is a live link with the rotating door code.{' '}
          <Link to="/developers#public-list-ticket-types" className="text-brand-primary hover:underline">Partner API reference</Link>
        </p>
      </div>

      {fresh && (
        <div className="bg-brand-primary/10 border border-brand-primary/40 p-3 space-y-2">
          <p className="text-xs text-white">Give this key to the partner now. It won't be shown again.</p>
          <div className="flex items-center gap-2">
            <code className="text-[11px] text-brand-primary break-all flex-1">{fresh}</code>
            <button type="button" className={BTN} onClick={() => navigator.clipboard?.writeText(fresh)} aria-label="Copy key">
              <Copy className="w-3 h-3" />
            </button>
            <button type="button" className={BTN} onClick={() => setFresh(null)} aria-label="Hide key">
              <EyeOff className="w-3 h-3" />
            </button>
          </div>
        </div>
      )}

      {canEdit && (
        <div className="flex flex-wrap items-end gap-2">
          <label className="flex flex-col gap-1">
            <span className="text-[10px] text-white/50 font-black uppercase tracking-widest">Partner</span>
            <select className={FLD} value={type} onChange={(e) => setType(e.target.value)}>
              {PARTNER_TYPES.map((t) => <option key={t} value={t}>{PARTNER_TYPE_LABEL[t]}</option>)}
            </select>
          </label>
          <label className="flex flex-col gap-1 flex-1 min-w-[10rem]">
            <span className="text-[10px] text-white/50 font-black uppercase tracking-widest">Name</span>
            <input className={FLD} value={label} maxLength={80} placeholder={PARTNER_TYPE_LABEL[type]} onChange={(e) => setLabel(e.target.value)} />
          </label>
          <label className="flex items-center gap-2 text-xs text-white/70 pb-2">
            <input type="checkbox" checked={comps} onChange={(e) => setComps(e.target.checked)} className="accent-brand-primary" />
            May issue comps
          </label>
          <button
            type="button" className={BTN} disabled={busy || live.length >= 25}
            onClick={() => run(async () => {
              const r = await createDistributionPartner(orgId, label.trim() || PARTNER_TYPE_LABEL[type], type,
                comps ? ['inventory', 'comps'] : ['inventory']);
              setFresh(r.key);
              setLabel('');
            }, 'Partner key created')}
          >
            <Plus className="w-3 h-3 inline" /> Add
          </button>
        </div>
      )}

      {rows === null ? (
        <p className="text-xs text-white/40">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-xs text-white/40">No partner keys yet.</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((p) => (
            <li key={p.id} className="bg-white/5 border border-white/10 px-3 py-2 flex flex-wrap items-center gap-2">
              <div className="flex-1 min-w-0">
                <p className="text-sm text-white">{p.label} <span className="text-white/40 text-xs">· {PARTNER_TYPE_LABEL[p.partner_type] ?? p.partner_type}</span></p>
                <p className="text-[11px] text-white/40">
                  <code>{p.key_prefix}…</code> · {p.scopes.join(', ')} ·{' '}
                  {p.revoked_at ? 'revoked' : p.active ? (p.last_used_at ? `last used ${new Date(p.last_used_at).toLocaleString()}` : 'never used') : 'paused'}
                </p>
              </div>
              {canEdit && !p.revoked_at && (
                <>
                  <button type="button" className={BTN} disabled={busy}
                    onClick={() => run(() => updateDistributionPartner(p.id, { active: !p.active }), p.active ? 'Paused' : 'Resumed')}>
                    {p.active ? 'Pause' : 'Resume'}
                  </button>
                  <button type="button" className={BTN} disabled={busy}
                    onClick={() => run(() => updateDistributionPartner(p.id, {
                      scopes: p.scopes.includes('comps') ? ['inventory'] : ['inventory', 'comps'],
                    }), 'Saved')}>
                    {p.scopes.includes('comps') ? 'Stop comps' : 'Allow comps'}
                  </button>
                  <button type="button" className={BTN} disabled={busy} aria-label={`Revoke ${p.label}`}
                    onClick={() => {
                      if (window.confirm(`Revoke ${p.label}'s key? Its open reservations are cancelled; completed orders stay.`)) {
                        run(() => revokeDistributionPartner(p.id), 'Revoked');
                      }
                    }}>
                    <Trash2 className="w-3 h-3" />
                  </button>
                </>
              )}
            </li>
          ))}
        </ul>
      )}
    </fieldset>
  );
}
