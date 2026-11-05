// The confirm screen after an OAuth sign-in (Connect Google Ads, Connect
// Eventbrite; mig 20261029140000). The org settings page shows it instead of
// the settings while a return is in hand (lib/oauthReturn.ts has the flow).
//
// - The state and finish token were read from the URL by the page and are
//   already gone from the address bar; the token is held here only, never
//   shown, logged, or sent anywhere but /finish.
// - Nothing is sent on load: the user sees which organization the account
//   will be connected to and clicks Confirm.
// - /finish refuses a sign-in started by another Exos account (someone who
//   sent this user an authorize link); the screen then says nothing was
//   connected.

import { useReducer } from 'react';
import { useNavigate } from 'react-router-dom';
import { Loader2, ShieldAlert } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { finishGoogleAdsConnect } from '../lib/adCredentials';
import { finishEventbriteConnect } from '../lib/door/eventbrite';
import { eventPickPath } from '../lib/eventbriteConnect';
import {
  confirmPrompt, finishBody, finishReducer, initialStep, providerLabel, refusalMessage, type OAuthReturn,
} from '../lib/oauthReturn';

const BTN = 'px-4 py-2 rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50';

export default function OAuthFinish({ ret, orgName, onClose }: {
  ret: OAuthReturn;
  /** null: this user can't see the org, so the sign-in wasn't started from this account. */
  orgName: string | null;
  onClose: () => void;
}) {
  const { toast } = useToast();
  const navigate = useNavigate();
  const [step, dispatch] = useReducer(finishReducer, ret, (r) => initialStep(r, orgName !== null));
  const label = providerLabel(step.provider);

  const confirm = async () => {
    const sending = finishReducer(step, { type: 'confirm' });
    const body = finishBody(sending);
    if (!body) return;
    dispatch({ type: 'confirm' });
    try {
      if (step.provider === 'google_ads') {
        await finishGoogleAdsConnect(body.state, body.finish);
        dispatch({ type: 'ok' });
        toast({ kind: 'success', message: 'Google Ads connected. Add the customer id and conversion action, then turn it on.' });
        onClose();
      } else {
        const r = await finishEventbriteConnect(body.state, body.finish);
        dispatch({ type: 'ok' });
        toast({ kind: 'success', message: `Eventbrite connected${r.accountName ? `: ${r.accountName}` : ''}.` });
        const pick = eventPickPath(r.eventId);
        if (pick) navigate(pick);
        else onClose();
      }
    } catch (e: any) {
      dispatch({ type: 'refused', reason: typeof e?.reason === 'string' ? e.reason : 'unknown' });
    }
  };

  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-lg mx-auto px-4 py-24">
        <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-4" role="dialog" aria-labelledby="oauth-finish-title">
          <h1 id="oauth-finish-title" className="text-sm font-black uppercase tracking-widest">Connect {label}</h1>

          {(step.step === 'confirm' || step.step === 'sending') && orgName !== null && (
            <>
              <p className="text-sm text-slate-700">{confirmPrompt(step.provider, orgName)}</p>
              <p className="text-xs text-slate-500">
                Only confirm if you started this from {orgName}’s settings yourself, just now. If someone sent you a
                link, click Cancel.
              </p>
              <div className="flex gap-2">
                <button type="button" onClick={() => void confirm()} disabled={step.step === 'sending'}
                  className={`${BTN} bg-tm-blue text-white inline-flex items-center gap-1`}>
                  {step.step === 'sending' && <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />} Confirm
                </button>
                <button type="button" onClick={() => dispatch({ type: 'cancel' })} disabled={step.step === 'sending'}
                  className={`${BTN} border border-slate-200 text-slate-600`}>
                  Cancel
                </button>
              </div>
            </>
          )}

          {step.step === 'refused' && (
            <p role="alert" className="text-sm text-rose-700 flex gap-2">
              <ShieldAlert className="w-4 h-4 shrink-0 mt-0.5" aria-hidden="true" />
              <span>{refusalMessage(step.provider, step.reason)}</span>
            </p>
          )}
          {step.step === 'cancelled' && (
            <p className="text-sm text-slate-600">Cancelled. Nothing was connected.</p>
          )}
          {(step.step === 'refused' || step.step === 'cancelled') && (
            <button type="button" onClick={() => (orgName !== null ? onClose() : navigate('/orgs'))}
              className={`${BTN} border border-slate-200 text-slate-600`}>
              {orgName !== null ? 'Back to settings' : 'My organizations'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
