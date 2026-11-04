// Partner presale (mig 20261104180000, docs/org-access.md): may distribution
// partners sell a ticket type while its member presale runs? The org's
// setting (owners) in Org settings, and one event's override (owners and
// managers) in the event editor. Exos's own checkout keeps members-only
// during the presale either way.

import { useCallback, useEffect, useState } from 'react';
import { useToast } from '../context/ToastContext';
import {
  getPartnerPresale, PARTNER_PRESALE_INFO, setEventPartnerPresale, setOrgPartnerPresale, type PartnerPresaleMode,
  type PartnerPresaleView,
} from '../lib/orgAccess';

const FLD = 'bg-black border border-white/20 px-3 py-2 text-xs text-white';

function useMessage() {
  const { toast } = useToast();
  return (e: unknown) => toast({ kind: 'error', message: String((e as Error)?.message ?? e).replace(/^[a-z_]+: /, '') });
}

/** Org settings: block (default) or allow. */
export default function PartnerPresalePanel({ orgId, canEdit }: { orgId: string; canEdit: boolean }) {
  const { toast } = useToast();
  const onErr = useMessage();
  const [view, setView] = useState<PartnerPresaleView | null>(null);
  useEffect(() => { getPartnerPresale(orgId).then(setView).catch(() => setView(null)); }, [orgId]);
  if (!view) return null;
  const change = (mode: PartnerPresaleMode) => setOrgPartnerPresale(orgId, mode)
    .then((v) => { setView(v); toast({ kind: 'success', message: 'Partner presale saved.' }); }).catch(onErr);
  return (
    <fieldset className="bg-[#111] rounded-2xl border border-white/10 p-5 space-y-3">
      <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">Partners during member presales</legend>
      {(['block', 'allow'] as const).map((m) => (
        <label key={m} className="flex items-start gap-2 text-xs text-white/70">
          <input type="radio" name="partner-presale" checked={view.org_mode === m} disabled={!canEdit} onChange={() => change(m)} />
          <span><span className="font-bold text-white">{m === 'block' ? 'Members first (default)' : 'Partners can sell too'}</span> · {PARTNER_PRESALE_INFO[m]}</span>
        </label>
      ))}
      <p className="text-[11px] text-white/40">Each event can override this in its editor.{!canEdit && ' Only the owner changes the default.'}</p>
    </fieldset>
  );
}

/** The event editor: follow the org, or block / allow for this event. */
export function EventPartnerPresale({ orgId, eventId, canEdit }: { orgId: string; eventId: string; canEdit: boolean }) {
  const { toast } = useToast();
  const onErr = useMessage();
  const [view, setView] = useState<PartnerPresaleView | null>(null);
  const load = useCallback(() => {
    getPartnerPresale(orgId, eventId).then(setView).catch(() => setView(null));
  }, [orgId, eventId]);
  useEffect(load, [load]);
  if (!view) return null;
  const value = view.event_mode ?? 'inherit';
  return (
    <label className="flex flex-col gap-1 text-xs text-white/70 max-w-md">
      <span className="text-[10px] text-white/50 font-black uppercase tracking-widest">Partners during the member presale</span>
      <select className={FLD} value={value} disabled={!canEdit}
        onChange={(e) => {
          const m = e.target.value === 'inherit' ? null : (e.target.value as PartnerPresaleMode);
          setEventPartnerPresale(eventId, m).then((v) => { setView(v); toast({ kind: 'success', message: 'Saved.' }); }).catch(onErr);
        }}>
        <option value="inherit">Organization default ({view.org_mode === 'allow' ? 'partners can sell' : 'members first'})</option>
        <option value="block">Members first: partners wait for the presale to end</option>
        <option value="allow">Partners can sell during the presale</option>
      </select>
      <span className="text-white/40">{PARTNER_PRESALE_INFO[view.effective ?? 'block']}</span>
    </label>
  );
}
