// What kind of organization this is (mig 20261105130000, docs/promoter-events.md):
// organizer, promoter or collective. A label plus defaults (a no-venue org's
// new events start as "a venue not on Exos", and the venue calendar stays out
// of the way); it never grants or removes a permission.
//   <OrgTypeChoice>  the radio group (onboarding, settings)
//   <OrgTypePanel>   the settings card: the owner changes it

import { useState } from 'react';
import { ORG_TYPE_INFO, ORG_TYPES, type OrgType } from '../lib/eventLocation';
import { setOrgType } from '../lib/eventLocationApi';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';

export function OrgTypeChoice({ value, onChange, disabled, name = 'org-type' }: {
  value: OrgType; onChange: (t: OrgType) => void; disabled?: boolean; name?: string;
}) {
  return (
    <div role="radiogroup" aria-label="What kind of organization" className="grid grid-cols-1 sm:grid-cols-3 gap-2">
      {ORG_TYPES.map((t) => (
        <label key={t} className={`border rounded-lg px-3 py-2.5 cursor-pointer text-sm ${value === t ? 'border-tm-blue bg-tm-blue/5' : 'border-slate-200'} ${disabled ? 'opacity-60 cursor-not-allowed' : ''}`}>
          <input type="radio" name={name} className="sr-only" checked={value === t} disabled={disabled}
            onChange={() => onChange(t)} />
          <span className="block font-bold text-slate-900">{ORG_TYPE_INFO[t].label}</span>
          <span className="block text-[11px] text-slate-500 mt-0.5">{ORG_TYPE_INFO[t].hint}</span>
        </label>
      ))}
    </div>
  );
}

export default function OrgTypePanel({ orgId, initial, canEdit }: { orgId: string; initial: OrgType; canEdit: boolean }) {
  const { toast } = useToast();
  const { refresh } = useOrganization();
  const [value, setValue] = useState<OrgType>(initial);
  const [saving, setSaving] = useState(false);
  const pick = async (t: OrgType) => {
    if (t === value || !canEdit) return;
    setSaving(true);
    try {
      await setOrgType(orgId, t);
      setValue(t);
      await refresh();
      toast({ kind: 'success', message: `Saved: ${ORG_TYPE_INFO[t].label}.` });
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Not saved.' });
    } finally {
      setSaving(false);
    }
  };
  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6">
      <h2 className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-3">Kind of organization</h2>
      <p className="text-xs text-slate-400 mb-4">
        Promoters and collectives run events with no venue of their own: venues not on Exos, pop-ups, warehouses, secret
        locations. It only changes defaults (new events start at a venue not on Exos; the booking calendar is tucked away).
        Nobody gains or loses access. {canEdit ? '' : 'The owner sets it.'}
      </p>
      <OrgTypeChoice value={value} onChange={(t) => void pick(t)} disabled={!canEdit || saving} name={`org-type-${orgId}`} />
    </div>
  );
}
