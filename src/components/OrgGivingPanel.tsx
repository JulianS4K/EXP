// Org settings → Giving (docs/giving.md, mig 20261030130000).
//
// Campaigns (owner / manager edit), cash / check gifts (owner / manager /
// finance), and the donations CSV. Totals come from the donations themselves
// (exos_public_giving_campaigns), never a counter a client could move.

import { useCallback, useEffect, useState } from 'react';
import { HeartHandshake, Download } from 'lucide-react';
import {
  donationsCsv, donationsExport, listCampaigns, majorToCents, recordOfflineDonation, saveCampaign, type GivingCampaign,
} from '../lib/commerce';
import { csvFileName, downloadCsv } from '../lib/csv';
import { publicUrl } from '../lib/utils';
import { useToast } from '../context/ToastContext';

const inputCls = 'bg-slate-50 border-2 border-transparent rounded-2xl py-2 px-4 text-slate-900 font-bold w-full focus:outline-none focus:border-brand-primary focus:bg-white';
const labelCls = 'text-[10px] font-black text-slate-400 uppercase tracking-widest';

const slugify = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 80) || 'give';

interface Props {
  orgId: string;
  orgSlug?: string | null;
  canEdit: boolean;
  canRecord: boolean;
}

export default function OrgGivingPanel({ orgId, orgSlug, canEdit, canRecord }: Props) {
  const { toast } = useToast();
  const [campaigns, setCampaigns] = useState<GivingCampaign[]>([]);
  const [draft, setDraft] = useState({ name: '', goal: '', addOn: true, roundUp: false, receipt: '' });
  const [gift, setGift] = useState({ campaignId: '', amount: '', method: 'check' as 'cash' | 'check' | 'other', name: '', email: '', note: '', ref: '' });

  const load = useCallback(async () => {
    try { setCampaigns(await listCampaigns(orgId)); } catch { /* RLS */ }
  }, [orgId]);
  useEffect(() => { load(); }, [load]);

  const add = async () => {
    try {
      await saveCampaign({
        org_id: orgId, name: draft.name.trim(), slug: slugify(draft.name), goal_cents: majorToCents(draft.goal || '0') ?? 0,
        checkout_add_on: draft.addOn, round_up: draft.roundUp, tax_receipt_text: draft.receipt.trim() || null,
      });
      setDraft({ name: '', goal: '', addOn: true, roundUp: false, receipt: '' });
      load();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save the campaign.' });
    }
  };

  const record = async () => {
    const cents = majorToCents(gift.amount);
    if (!gift.campaignId || !cents) { toast({ kind: 'error', message: 'Pick a campaign and an amount.' }); return; }
    try {
      await recordOfflineDonation({
        campaignId: gift.campaignId, amountCents: cents, method: gift.method, donorName: gift.name, donorEmail: gift.email,
        note: gift.note, externalId: gift.ref || undefined,
      });
      toast({ kind: 'success', message: 'Donation recorded.' });
      setGift({ ...gift, amount: '', name: '', email: '', note: '', ref: '' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not record it.' });
    }
  };

  const exportCsv = async () => {
    try {
      const rows = await donationsExport(orgId);
      downloadCsv(csvFileName(['donations']), donationsCsv(rows));
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not export.' });
    }
  };

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6">
      <div className="flex items-center justify-between mb-2">
        <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest flex items-center gap-2"><HeartHandshake className="w-4 h-4" /> Giving</h2>
        <button onClick={exportCsv} className="text-xs underline flex items-center gap-1"><Download className="w-3 h-3" /> Donations CSV</button>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Campaigns get a public page and can be offered as add-a-donation at ticket checkout (its own line after tax,
        no fees). Every gift with an email gets a numbered receipt with your receipt text.
      </p>
      <div className="space-y-2 mb-4 text-sm">
        {campaigns.map((c) => (
          <div key={c.id} className="flex items-center justify-between">
            <span className="font-bold">{c.name}{c.active === false ? ' (off)' : ''}</span>
            <span className="text-xs text-slate-500 space-x-3">
              {orgSlug && <a className="underline" href={publicUrl(`give/${orgSlug}/${c.slug}`)}>Page</a>}
              {c.checkout_add_on && <span>at checkout</span>}
              {canEdit && <button className="underline" onClick={async () => { await saveCampaign({ ...c, active: !c.active }); load(); }}>{c.active ? 'Turn off' : 'Turn on'}</button>}
            </span>
          </div>
        ))}
        {campaigns.length === 0 && <p className="text-xs text-slate-400">No campaigns yet.</p>}
      </div>
      {canEdit && (
        <div className="grid grid-cols-2 gap-2 mb-6">
          <label><span className={labelCls}>Campaign</span><input className={inputCls} value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} placeholder="Roof fund" /></label>
          <label><span className={labelCls}>Goal (optional)</span><input className={inputCls} inputMode="decimal" value={draft.goal} onChange={(e) => setDraft({ ...draft, goal: e.target.value })} /></label>
          <label className="col-span-2"><span className={labelCls}>Receipt text (legal name, charity status, tax id)</span>
            <textarea className={inputCls} rows={2} value={draft.receipt} onChange={(e) => setDraft({ ...draft, receipt: e.target.value })} /></label>
          <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={draft.addOn} onChange={(e) => setDraft({ ...draft, addOn: e.target.checked })} /> Offer at ticket checkout</label>
          <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={draft.roundUp} onChange={(e) => setDraft({ ...draft, roundUp: e.target.checked })} /> Offer round-up</label>
          <button disabled={!draft.name.trim()} onClick={add} className="col-span-2 bg-slate-900 text-white rounded-2xl py-2 text-xs font-black uppercase disabled:opacity-40">Add campaign</button>
        </div>
      )}
      {canRecord && campaigns.length > 0 && (
        <div className="border-t border-slate-100 pt-4">
          <h3 className={`${labelCls} mb-2`}>Record a cash or check gift</h3>
          <div className="grid grid-cols-2 gap-2">
            <select className={inputCls} value={gift.campaignId} onChange={(e) => setGift({ ...gift, campaignId: e.target.value })}>
              <option value="">Campaign…</option>
              {campaigns.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
            <input className={inputCls} placeholder="Amount" inputMode="decimal" value={gift.amount} onChange={(e) => setGift({ ...gift, amount: e.target.value })} />
            <select className={inputCls} value={gift.method} onChange={(e) => setGift({ ...gift, method: e.target.value as typeof gift.method })}>
              <option value="check">Check</option><option value="cash">Cash</option><option value="other">Other</option>
            </select>
            <input className={inputCls} placeholder="Check no. / reference (prevents doubles)" value={gift.ref} onChange={(e) => setGift({ ...gift, ref: e.target.value.replace(/[^A-Za-z0-9_:.-]/g, '') })} />
            <input className={inputCls} placeholder="Donor name" value={gift.name} onChange={(e) => setGift({ ...gift, name: e.target.value })} />
            <input className={inputCls} placeholder="Donor email (for the receipt)" value={gift.email} onChange={(e) => setGift({ ...gift, email: e.target.value })} />
          </div>
          <button onClick={record} className="mt-2 bg-brand-primary text-black rounded-2xl py-2 px-4 text-xs font-black uppercase">Record</button>
        </div>
      )}
    </div>
  );
}
