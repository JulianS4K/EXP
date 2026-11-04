// Edit event → Sell through partners → Caps (mig 20261104200000,
// docs/partner-sales.md "Caps"). Optional: the most tickets one partner may
// hold + sell, for the whole event or one ticket type. Blank = no cap (every
// partner shares what is left, as before). Owners and managers; hidden when
// the RPC isn't on this database or the role can't read it.

import { useCallback, useEffect, useState } from 'react';
import { useToast } from '../context/ToastContext';
import { sqlMessage, type DistributionPartner, type TierDistribution } from '../lib/developerPlatform';
import {
  capSummary, fetchPartnerCaps, findCap, parseCapField, setPartnerCaps, type PartnerCap, type PartnerCapInput,
} from '../lib/partnerCapsApi';

const BTN = 'text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const EVENT = '__event';

export default function PartnerCapsPanel({ eventId, tiers, partners }: {
  eventId: string; tiers: TierDistribution[]; partners: DistributionPartner[];
}) {
  const { toast } = useToast();
  const [caps, setCaps] = useState<PartnerCap[] | null>(null);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(() => {
    void fetchPartnerCaps(eventId).then(setCaps);
  }, [eventId]);
  useEffect(load, [load]);

  const sellable = tiers.filter((t) => t.enabled && !t.table);
  if (!caps || partners.length === 0 || sellable.length === 0) return null;

  const key = (p: string, t: string | null) => `${p}:${t ?? EVENT}`;
  const shown = (p: string, t: string | null) => {
    const k = key(p, t);
    if (k in draft) return draft[k];
    const c = findCap(caps, p, t);
    return c ? String(c.max_tickets) : '';
  };
  const columns: { id: string | null; name: string }[] = [{ id: null, name: 'Whole event' }, ...sellable.map((t) => ({ id: t.tier_id, name: t.name }))];

  const save = async (partnerId: string) => {
    const changes: PartnerCapInput[] = [];
    for (const col of columns) {
      const k = key(partnerId, col.id);
      if (!(k in draft)) continue;
      const v = parseCapField(draft[k]);
      if (v === undefined) {
        toast({ kind: 'error', message: `${col.name}: a whole number from 0 to 100000, or blank for no cap` });
        return;
      }
      const had = findCap(caps, partnerId, col.id);
      if (v === null && !had) continue;
      if (had && v === had.max_tickets) continue;
      changes.push({ partner_id: partnerId, tier_id: col.id, max_tickets: v });
    }
    if (changes.length === 0) return;
    setBusy(partnerId);
    try {
      setCaps(await setPartnerCaps(eventId, changes));
      setDraft((d) => Object.fromEntries(Object.entries(d).filter(([k]) => !k.startsWith(`${partnerId}:`))));
      toast({ kind: 'success', message: 'Caps saved' });
    } catch (e) {
      toast({ kind: 'error', message: sqlMessage(e) });
      load();
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="space-y-3 pt-2 border-t border-white/10">
      <h3 className="text-[11px] font-black uppercase tracking-widest text-white/70">Caps per partner (optional)</h3>
      <p className="text-xs text-white/40">
        The most tickets one partner may hold or sell. Their live holds and valid sales count; cancelled, expired and
        refunded ones don't. Leave blank for no cap. Past the cap the partner is told how many are left.
      </p>
      <div className="overflow-x-auto">
        <table className="w-full text-left text-xs min-w-[480px]">
          <thead>
            <tr className="text-[10px] uppercase tracking-widest text-white/40">
              <th className="py-2 pr-3">Partner</th>
              {columns.map((c) => <th key={c.id ?? EVENT} className="py-2 pr-3">{c.name}</th>)}
              <th className="py-2" />
            </tr>
          </thead>
          <tbody>
            {partners.map((p) => (
              <tr key={p.id} className="border-t border-white/5 align-top">
                <td className="py-2 pr-3 text-white">{p.label}</td>
                {columns.map((col) => {
                  const c = findCap(caps, p.id, col.id);
                  const bad = parseCapField(shown(p.id, col.id)) === undefined;
                  return (
                    <td key={col.id ?? EVENT} className="py-2 pr-3">
                      <input
                        inputMode="numeric" aria-label={`${p.label} cap for ${col.name}`} placeholder="no cap"
                        className={`w-20 bg-black border px-2 py-1 text-white ${bad ? 'border-red-500' : 'border-white/20'}`}
                        value={shown(p.id, col.id)} disabled={busy === p.id}
                        onChange={(e) => setDraft((d) => ({ ...d, [key(p.id, col.id)]: e.target.value }))} />
                      {c && <div className="text-[10px] text-white/40 mt-1">{capSummary(c)}</div>}
                    </td>
                  );
                })}
                <td className="py-2">
                  <button type="button" className={BTN} disabled={busy === p.id} onClick={() => save(p.id)}>Save</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
