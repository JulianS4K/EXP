// Settings → Legal & invoices (mig 20261001100000, docs/invoices.md). The
// seller details printed on receipts and credit notes: legal name, address,
// tax id, footer. Owner / manager / finance (RLS on exos_org_legal enforces
// the same); never shown on public pages. Each receipt keeps the details it
// was issued with, so a change applies to new receipts only.

import { useEffect, useState } from 'react';
import { useToast } from '../context/ToastContext';
import { LEGAL_LIMITS, validateOrgLegal, type OrgLegal } from '../lib/invoices';
import { getOrgLegal, saveOrgLegal } from '../lib/invoicesApi';

const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2';
const FLD =
  'w-full bg-white border border-slate-200 rounded-lg px-4 py-3 text-sm text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-tm-blue transition-colors disabled:opacity-60 disabled:bg-slate-50';

const EMPTY: OrgLegal = { legal_name: '', legal_address: '', tax_id: '', invoice_footer: '' };

export default function OrgLegalSettings({ orgId, orgName }: { orgId: string; orgName: string }) {
  const { toast } = useToast();
  // undefined = loading, null = not available (older schema / no access).
  const [value, setValue] = useState<OrgLegal | null | undefined>(undefined);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void getOrgLegal(orgId).then((v) => { if (!cancelled) setValue(v); });
    return () => { cancelled = true; };
  }, [orgId]);

  if (value === null) return null;
  const v = value ?? EMPTY;
  const errors = validateOrgLegal(v);
  const set = (k: keyof OrgLegal) => (e: { target: { value: string } }) => setValue({ ...v, [k]: e.target.value });

  const save = async () => {
    if (Object.keys(errors).length > 0) {
      toast({ kind: 'error', message: 'Shorten the fields marked in red.' });
      return;
    }
    setSaving(true);
    try {
      await saveOrgLegal(orgId, v);
      toast({ kind: 'success', message: 'Legal details saved. New receipts will show them.' });
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save the legal details.' });
    } finally {
      setSaving(false);
    }
  };

  const field = (k: keyof OrgLegal, label: string, opts: { area?: boolean; placeholder?: string } = {}) => (
    <div>
      <label htmlFor={`legal-${k}`} className={LBL}>{label}</label>
      {opts.area ? (
        <textarea id={`legal-${k}`} rows={3} value={v[k]} onChange={set(k)} disabled={value === undefined || saving}
          placeholder={opts.placeholder} className={FLD} aria-invalid={!!errors[k]} />
      ) : (
        <input id={`legal-${k}`} value={v[k]} onChange={set(k)} disabled={value === undefined || saving}
          placeholder={opts.placeholder} className={FLD} aria-invalid={!!errors[k]} />
      )}
      {errors[k] ? (
        <p className="text-[11px] text-rose-600 mt-1">{errors[k]}</p>
      ) : (
        <p className="text-[10px] text-slate-400 mt-1">{v[k].trim().length} / {LEGAL_LIMITS[k]}</p>
      )}
    </div>
  );

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8">
      <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest mb-2">Legal &amp; invoices</h2>
      <p className="text-xs text-slate-400 mb-6">
        Printed as the seller on your buyers' receipts and credit notes. Leave the legal name blank to use
        "{orgName}". Only owners, managers and finance see these; they aren't on your public pages.
        Receipts keep the details they were issued with.
      </p>
      <div className="grid gap-5">
        {field('legal_name', 'Legal name', { placeholder: orgName })}
        {field('legal_address', 'Address', { area: true, placeholder: '1 Main St\nBrooklyn, NY 11201' })}
        {field('tax_id', 'Tax ID (EIN, VAT or sales-tax number)')}
        {field('invoice_footer', 'Receipt footer', { area: true, placeholder: 'Questions? hello@example.com' })}
      </div>
      <button type="button" onClick={save} disabled={value === undefined || saving}
        className="mt-6 px-5 py-2.5 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-700 hover:border-tm-blue hover:text-tm-blue transition-colors disabled:opacity-50">
        {saving ? 'Saving…' : 'Save legal details'}
      </button>
    </div>
  );
}
