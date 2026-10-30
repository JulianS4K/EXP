// Edit event → Sell through partners (mig 20261031130000, docs/partner-sales.md).
// Per ticket type: whether distribution partners may sell it (off by
// default), which ones (none ticked = every partner of the org), and a pause
// that stops it without forgetting who may sell. Owners and managers; hidden
// for everyone else and when the org has no partner keys.

import { useCallback, useEffect, useState } from 'react';
import { Handshake } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  fetchTierDistribution, listDistributionPartners, setTierDistribution, sqlMessage,
  type DistributionPartner, type TierDistribution,
} from '../lib/developerPlatform';

const BTN = 'text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';

export default function TierDistributionPanel({ eventId, orgId }: { eventId: string; orgId?: string }) {
  const { toast } = useToast();
  const [tiers, setTiers] = useState<TierDistribution[] | null>(null);
  const [partners, setPartners] = useState<DistributionPartner[]>([]);
  const [hidden, setHidden] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    if (!orgId) return;
    Promise.all([fetchTierDistribution(eventId), listDistributionPartners(orgId)])
      .then(([t, p]) => {
        const live = p.filter((x) => !x.revoked_at);
        if (live.length === 0) setHidden(true);
        setPartners(live);
        setTiers(t);
      })
      .catch(() => setHidden(true));
  }, [eventId, orgId]);
  useEffect(load, [load]);
  if (hidden || !tiers) return null;

  const save = async (t: TierDistribution) => {
    setBusy(true);
    try {
      setTiers(await setTierDistribution(eventId, [{ tier_id: t.tier_id, enabled: t.enabled, partner_ids: t.partner_ids, paused: t.paused }]));
      toast({ kind: 'success', message: 'Saved' });
    } catch (e) {
      toast({ kind: 'error', message: sqlMessage(e) });
      load();
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-4">
      <div className="flex items-center gap-2">
        <Handshake className="w-4 h-4 text-brand-primary" aria-hidden="true" />
        <h2 className="text-sm font-black uppercase tracking-widest text-white">Sell through partners</h2>
      </div>
      <p className="text-xs text-white/40">
        Switch a ticket type on to let your distribution partners reserve and sell it at its all-in price. Their
        holds count against every channel, so nothing oversells. Leave every partner unticked for all of them.
      </p>
      <ul className="space-y-3">
        {tiers.map((t) => (
          <li key={t.tier_id} className="bg-white/5 border border-white/10 px-3 py-3 space-y-2">
            <div className="flex flex-wrap items-center gap-3">
              <span className="text-sm text-white flex-1">{t.name}</span>
              {t.table ? (
                <span className="text-[11px] text-white/40">Tables aren't sold through partners</span>
              ) : (
                <>
                  <label className="flex items-center gap-2 text-xs text-white/80">
                    <input type="checkbox" className="accent-brand-primary" checked={t.enabled} disabled={busy}
                      onChange={(e) => save({ ...t, enabled: e.target.checked })} />
                    Partners may sell
                  </label>
                  {t.enabled && (
                    <button type="button" className={BTN} disabled={busy} onClick={() => save({ ...t, paused: !t.paused })}>
                      {t.paused ? 'Resume' : 'Pause'}
                    </button>
                  )}
                </>
              )}
            </div>
            {t.enabled && !t.table && (
              <div className="flex flex-wrap gap-3">
                {partners.map((p) => (
                  <label key={p.id} className="flex items-center gap-1.5 text-[11px] text-white/60">
                    <input type="checkbox" className="accent-brand-primary" disabled={busy}
                      checked={t.partner_ids.includes(p.id)}
                      onChange={(e) => save({
                        ...t,
                        partner_ids: e.target.checked ? [...t.partner_ids, p.id] : t.partner_ids.filter((x) => x !== p.id),
                      })} />
                    {p.label}
                  </label>
                ))}
                <span className="text-[11px] text-white/30">
                  {t.partner_ids.length === 0 ? 'Every partner' : `${t.partner_ids.length} partner(s)`}{t.paused ? ' · paused' : ''}
                </span>
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
