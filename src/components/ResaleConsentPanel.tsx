// Edit event → Marketplaces → Resale (mig 20261029090000): whether the event
// is the free tier (max capacity 150 or less: no Exos fee, never resold), and
// for bigger events the per-event opt-in, with the text it stands for, and
// the way to withdraw it.

import { useCallback, useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  fetchSalesRules, RESALE_CONSENT_TEXT, RESALE_CONSENT_VERSION, salesRulesLine, setResaleConsent, type SalesRules,
} from '../lib/marketplace/resaleConsent';

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';

export default function ResaleConsentPanel({ eventId, refreshKey, onRules }: {
  eventId: string;
  /** Changes when the saved capacity may have changed (re-read). */
  refreshKey?: string;
  onRules?: (rules: SalesRules | null) => void;
}) {
  const { toast } = useToast();
  const [rules, setRules] = useState<SalesRules | null>(null);
  const [hidden, setHidden] = useState(false);
  const [agreed, setAgreed] = useState(false);
  const [busy, setBusy] = useState(false);

  const apply = useCallback((r: SalesRules | null) => {
    setRules(r);
    onRules?.(r);
  }, [onRules]);
  useEffect(() => {
    fetchSalesRules(eventId).then((r) => (r ? apply(r) : setHidden(true))).catch(() => setHidden(true));
  }, [eventId, refreshKey, apply]);
  if (hidden || !rules) return null;

  const change = async (on: boolean) => {
    setBusy(true);
    try {
      const r = await setResaleConsent(eventId, on);
      apply(r);
      setAgreed(false);
      toast({ kind: 'success', message: on ? 'Resale is on for this event.' : 'Resale is off: listings come down and their seats come back.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Not saved.' });
    } finally {
      setBusy(false);
    }
  };

  const big = rules.maxCapacity > rules.freeTierMaxCapacity;
  const stale = rules.consentVersion !== '' && rules.consentVersion !== RESALE_CONSENT_VERSION;
  const tone = rules.freeTier ? 'text-brand-primary' : rules.resaleUnlocked ? 'text-white/70' : 'text-amber-400';

  return (
    <div className="space-y-3 border border-white/10 p-4" aria-label="Resale">
      <p className="type text-[11px] text-white/60 uppercase tracking-widest">Resale</p>
      <p role="status" className={`type text-xs ${tone}`}>{salesRulesLine(rules)}</p>

      {big && rules.consent && (
        <div className="space-y-2">
          <p className="type text-xs text-white/50">
            Opted in{rules.consent.givenByEmail ? ` by ${rules.consent.givenByEmail}` : ''}
            {rules.consent.givenAt ? ` on ${new Date(rules.consent.givenAt).toLocaleString()}` : ''}
            {` (max capacity ${rules.consent.maxCapacityAtConsent} then).`}
          </p>
          {rules.canManage && (
            <button type="button" className={BTN} disabled={busy} onClick={() => void change(false)}>
              Withdraw: take this event off resale
            </button>
          )}
        </div>
      )}

      {big && !rules.consent && rules.consentRequired && (
        rules.canManage ? (
          <div className="space-y-3">
            <div className="space-y-2 border-l-2 border-white/20 pl-3">
              {RESALE_CONSENT_TEXT.map((p) => <p key={p} className="type text-xs text-white/70 leading-relaxed">{p}</p>)}
            </div>
            {stale ? (
              <p role="alert" className="type text-xs text-rose-400">The resale terms changed. Reload the page to read the current ones.</p>
            ) : (
              <>
                <label className="flex items-start gap-2 cursor-pointer">
                  <input type="checkbox" className="mt-0.5 w-4 h-4 accent-brand-primary" checked={agreed}
                    onChange={(e) => setAgreed(e.target.checked)} />
                  <span className="type text-xs text-white/80">I agree to resale for this event, as written above.</span>
                </label>
                <div className="flex items-center gap-3">
                  <button type="button" className={BTN} disabled={busy || !agreed} onClick={() => void change(true)}>Opt in to resale</button>
                  {busy && <Loader2 className="w-3 h-3 animate-spin text-white/50" />}
                </div>
              </>
            )}
          </div>
        ) : (
          <p className="type text-xs text-white/40">An owner or manager can opt this event in to resale.</p>
        )
      )}
    </div>
  );
}
