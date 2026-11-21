// On-sale waiting room (mig 20261118120000) in front of the buy box. On load
// the page asks the server whether this event's room is open
// (exos_wroom_join): no room, or a room that closed, shows the buy box as
// usual; otherwise the browser gets a queue token and sees its own place in
// line until it is admitted. Works signed out. Polls politely: the server
// suggests the pace (farther back = slower), the page adds jitter, and it
// checks again when the tab comes back into view. The SQL gate in checkout
// and the hold functions is what enforces the line; this only shows it.

import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { Clock } from 'lucide-react';
import {
  TURNSTILE_SITE_KEY, blocksBuying, challengeMode, endCheckout, joinRoom, joinWithChallenge, nextPollMs, pollRoom, queueView,
  rejoinRoom, type RoomStatus,
} from '../lib/waitingRoom';
import TurnstileWidget from './TurnstileWidget';
import { useAuth } from '../context/AuthContext';
import { platform } from '../lib/platform/adapters';
import { isNativeApp } from '../lib/platform/native';
import { publicUrl } from '../lib/utils';

function timeIn(d: Date, tz?: string | null): string {
  try {
    return d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit', timeZone: tz || undefined });
  } catch {
    return d.toLocaleTimeString();
  }
}

export function WaitingRoomQueue({ status, timezone, onRejoin, busy, siteKey = TURNSTILE_SITE_KEY, onChallenge, onSignIn,
  onEndCheckout, note, browserUrl }: {
  status: RoomStatus; timezone?: string | null; onRejoin: () => void; busy?: boolean;
  siteKey?: string; onChallenge?: (token: string) => void;
  /** 'checking_out' on a Stripe page: cancel it and join again. */
  onEndCheckout?: () => void;
  /** A one-line answer to the last action (e.g. the page is being paid). */
  note?: string | null;
  /** Signed out: offered when the guest line is full (an established account gets a place). */
  onSignIn?: () => void;
  /** The native app: the human check runs on this public page in the browser sheet instead (an app web
   *  view reports "localhost" to Turnstile, which the server refuses). */
  browserUrl?: string;
}) {
  const v = queueView(status, (d) => timeIn(d, timezone));
  const mode = challengeMode(status, siteKey);
  const titleId = useId();
  return (
    <section data-waiting-room aria-labelledby={titleId} className="border border-white/15 bg-white/5 p-5 space-y-3">
      <p className="type text-[11px] uppercase tracking-widest text-white/60 flex items-center gap-2">
        <Clock className="w-4 h-4" aria-hidden="true" /> Waiting room
      </p>
      <div role="status" aria-live="polite" aria-atomic="true">
        <h2 id={titleId} className="disp text-2xl text-white leading-tight">{v.heading}</h2>
        {v.detail && <p className="type mt-2 text-[12px] text-white/75 leading-relaxed">{v.detail}</p>}
      </div>
      {status.state === 'waiting' && status.ahead != null && status.position != null && (
        <div>
          <div className="h-1.5 w-full bg-white/10" aria-hidden="true">
            <div className="h-1.5 bg-brand-primary transition-all"
              style={{ width: `${Math.max(4, Math.min(100, 100 - (status.ahead / Math.max(status.position, 1)) * 100))}%` }} />
          </div>
        </div>
      )}
      {mode === 'widget' && onChallenge && !browserUrl && <TurnstileWidget siteKey={siteKey} onToken={onChallenge} />}
      {mode === 'widget' && browserUrl && (
        <button type="button" onClick={() => void platform().openExternal(browserUrl)}
          className="disp w-full bg-brand-primary text-black py-3 text-lg tracking-wide">
          Join the line in the browser
        </button>
      )}
      {mode === 'unavailable' && (
        <p className="type text-[12px] text-white/75">This waiting room can't take new places right now. Try again later.</p>
      )}
      {status.state === 'full' && onSignIn && (
        <button type="button" onClick={onSignIn}
          className="disp w-full bg-brand-primary text-black py-3 text-lg tracking-wide">
          Sign in to get a place
        </button>
      )}
      {status.state === 'checking_out' && status.stripe && onEndCheckout && (
        <button type="button" onClick={onEndCheckout} disabled={busy}
          className="disp w-full bg-brand-primary text-black py-3 text-lg tracking-wide disabled:opacity-50">
          Cancel that payment page and join again
        </button>
      )}
      {note && <p role="alert" className="type text-[12px] text-white/80">{note}</p>}
      {v.rejoin && (
        <button type="button" onClick={onRejoin} disabled={busy}
          className="disp w-full bg-brand-primary text-black py-3 text-lg tracking-wide disabled:opacity-50">
          Join the line again
        </button>
      )}
      <p className="type text-[10px] text-white/50 leading-relaxed">
        One place per browser: opening more tabs doesn't move you up. Nothing here needs you to sign in.
      </p>
    </section>
  );
}

/** Shows the queue while it holds this browser back, the children otherwise. */
export default function WaitingRoomGate({ eventId, timezone, children, siteKey = TURNSTILE_SITE_KEY }: {
  eventId: string; timezone?: string | null; children: ReactNode; siteKey?: string;
}) {
  const { user, openAuthModal } = useAuth();
  const uid = user?.uid ?? null;
  const [status, setStatus] = useState<RoomStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const alive = useRef(true);
  const last = useRef<RoomStatus | null>(null);

  const schedule = useCallback((s: RoomStatus, run: (join: boolean) => void) => {
    if (timer.current) clearTimeout(timer.current);
    if (s.state === 'off' || s.state === 'challenge') return;   // no room / waiting on the check: nothing to poll
    timer.current = setTimeout(() => run(s.state === 'before' || s.state === 'busy' || s.state === 'unknown' || s.state === 'full'
      || s.state === 'checking_out'),
      nextPollMs(s));
  }, []);

  const run = useCallback(async (join: boolean) => {
    try {
      const s = join ? await joinRoom(eventId) : await pollRoom(eventId);
      if (!alive.current) return;
      last.current = s;
      setStatus(s);
      schedule(s, (j) => void run(j));
    } catch {
      if (!alive.current) return;
      // No room function yet, or the network blinked: the page stays usable
      // (checkout checks the line itself); a known line keeps polling.
      const prev = last.current;
      if (!prev) { setStatus({ state: 'off' }); return; }
      schedule({ ...prev, pollAfterMs: 15000 }, (j) => void run(j));
    }
    // A sign-in changes who asks: the account's own place (uid in the deps).
  }, [eventId, schedule, uid]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    alive.current = true;
    void run(true);
    const onVisible = () => {
      const s = last.current;
      if (document.visibilityState === 'visible' && s && s.state !== 'off' && s.state !== 'admitted') void run(false);
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      alive.current = false;
      if (timer.current) clearTimeout(timer.current);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [run]);

  const rejoin = async () => {
    setBusy(true);
    try {
      const s = await rejoinRoom(eventId);
      last.current = s;
      setStatus(s);
      schedule(s, (j) => void run(j));
    } catch {
      /* keep the current view; the next poll tries again */
    } finally {
      setBusy(false);
    }
  };

  const endOpenCheckout = async () => {
    setBusy(true);
    setNote(null);
    try {
      const r = await endCheckout(eventId);
      if (r === 'in_use') {
        setNote('That payment page is being paid right now. Check your email for your tickets.');
        return;
      }
      const s = await joinRoom(eventId);
      last.current = s;
      setStatus(s);
      schedule(s, (j) => void run(j));
    } catch {
      setNote("Couldn't cancel it just now. Try again in a moment.");
    } finally {
      setBusy(false);
    }
  };

  const challenge = async (token: string) => {
    setBusy(true);
    try {
      const s = await joinWithChallenge(eventId, token);
      last.current = s;
      setStatus(s);
      schedule(s, (j) => void run(j));
    } catch {
      /* keep the check on screen; the widget can be solved again */
    } finally {
      setBusy(false);
    }
  };

  // Until the first answer, show the buy box (most events have no room).
  if (status && blocksBuying(status)) {
    return <WaitingRoomQueue status={status} timezone={timezone} onRejoin={() => void rejoin()} busy={busy}
      siteKey={siteKey} onChallenge={(t) => void challenge(t)}
      onSignIn={uid || status.signedIn ? undefined : openAuthModal}
      onEndCheckout={() => void endOpenCheckout()} note={note}
      browserUrl={isNativeApp() ? publicUrl(`event/${eventId}`) : undefined} />;
  }
  return (
    <>
      {status?.state === 'admitted' && (
        <div data-waiting-room-admitted role="status" className="mb-3 border border-brand-primary/50 bg-brand-primary/10 p-3">
          <p className="type text-[12px] text-white leading-relaxed">
            {queueView(status, (d) => timeIn(d, timezone)).heading}. {queueView(status, (d) => timeIn(d, timezone)).detail}
          </p>
        </div>
      )}
      {children}
    </>
  );
}
