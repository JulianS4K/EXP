// OrderProofPanel: the guest's "confirm your email to get your tickets" step
// (mig 20261105100000, SIM-BUYER-12/13). Shown on the page the buyer comes
// back to after paying. The order is paid and the seats are saved; the
// tickets are released once the buyer types the 6-digit code mailed to the
// address they entered, or proves a phone by SMS instead (the way out of a
// mistyped email). The browser token from exos-checkout gates every call:
// from localStorage, or, where an in-app browser blocks storage, from the
// return URL's fragment (#pt=, the parent passes it in; lib/orderProof.ts).
// The token alone releases nothing; the code is still needed.
// No card field on this page (docs/pci.md).

import { useEffect, useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import {
  getProofStatus, proofErrorMessage, recallProofToken, sendProofCode, verifyProofCode,
  type ProofClaimLink, type ProofState,
} from '../lib/orderProof';

export default function OrderProofPanel({ sessionId, initialCode, token: given, emailHint, onSignIn }: {
  sessionId: string;
  /** From the mailed link (?proof_code=): tried once on load. */
  initialCode?: string | null;
  /** The browser token when the page read it from the URL fragment (#pt=). */
  token?: string | null;
  /** The masked inbox from the return URL (?to=j***@gmail.com), when known. */
  emailHint?: string | null;
  onSignIn: (email: string) => void;
}) {
  // Read once: the fragment is gone from the URL after the first read.
  const [token] = useState<string | null>(() => recallProofToken(sessionId) ?? given ?? null);
  const [state, setState] = useState<ProofState | null>(null);
  const [code, setCode] = useState(initialCode ?? '');
  const [phone, setPhone] = useState('');
  const [usePhone, setUsePhone] = useState(false);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [links, setLinks] = useState<ProofClaimLink[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const done = (attached: boolean, tickets: ProofClaimLink[]) => {
    setState((s) => ({ ...(s ?? { attemptsLeft: 0, tickets: [] }), status: 'proven', attached, tickets }));
    setLinks(tickets);
  };

  const verify = async (c: string) => {
    if (!token) return;
    setBusy(true); setErr(null);
    try {
      const r = await verifyProofCode(sessionId, token, c);
      if (r.ok) done(!!r.attached, r.tickets ?? []);
      else setErr(proofErrorMessage(r.error, { attempts_left: r.attempts_left }));
    } catch {
      setErr(proofErrorMessage(undefined));
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    if (!token) return undefined;
    let alive = true;
    getProofStatus(sessionId, token).then((s) => {
      if (!alive) return;
      setState(s);
      setLinks(s.tickets);
      if (s.status === 'pending' && initialCode) void verify(initialCode);
    }).catch(() => alive && setState({ status: 'unknown', attemptsLeft: 0, attached: false, tickets: [] }));
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, token]);

  const send = async (channel: 'email' | 'sms') => {
    if (!token) return;
    setBusy(true); setErr(null);
    try {
      const r = await sendProofCode(sessionId, token, channel, channel === 'sms' ? phone : undefined);
      if (r.ok) { setSentTo(r.to ?? null); setCode(''); } else setErr(proofErrorMessage(r.error));
    } catch {
      setErr(proofErrorMessage(undefined));
    } finally {
      setBusy(false);
    }
  };

  const submit = (e: FormEvent) => { e.preventDefault(); void verify(code); };

  if (!token || state?.status === 'unknown') {
    return (
      <p className="text-white/70 mb-6">
        To get your tickets, enter the code we emailed{emailHint ? <> to <strong className="text-white">{emailHint}</strong></> : null} on
        the device and browser you paid on.
        Paid somewhere else, or can't find the email? Ask the organizer to resend your tickets.
      </p>
    );
  }
  if (!state) return <p className="text-white/50 mb-6" role="status">Loading…</p>;
  if (state.status === 'cancelled') return <p className="text-white/70 mb-6">This order was refunded.</p>;
  if (state.status === 'expired') return <p className="text-white/70 mb-6">{proofErrorMessage('expired')}</p>;

  if (state.status === 'proven') {
    return (
      <div className="mb-6 text-white/70" role="status">
        <p className="font-bold text-white mb-2">Confirmed.</p>
        {state.attached ? (
          <>
            <p className="mb-4">Your tickets are in the Exos account for {state.email ?? 'that email'}. Sign in with it to see your QR codes.</p>
            <button onClick={() => onSignIn('')} className="bg-brand-primary text-black font-black uppercase tracking-wider px-8 py-3">
              Sign in to see tickets
            </button>
          </>
        ) : links.length > 0 ? (
          <>
            <p className="mb-3">Open a link to claim each ticket into your account (sign in with a one-time code, no password). Send a link to a friend and they claim that one.</p>
            <ul className="space-y-1">
              {links.map((l, i) => (
                <li key={l.ticket_id || i}><Link className="underline text-brand-primary" to={l.path}>Claim ticket {i + 1}</Link></li>
              ))}
            </ul>
          </>
        ) : (
          <p>We emailed your ticket links to {state.email ?? 'your email'}.</p>
        )}
      </div>
    );
  }

  return (
    <div className="mb-6 text-left text-white/70">
      <p className="mb-3">
        Your seats are saved. To get your tickets, enter the 6-digit code we emailed to{' '}
        <strong className="text-white">{sentTo ?? state.email ?? emailHint ?? 'your email'}</strong>.
      </p>
      <form onSubmit={submit} className="flex gap-2 mb-2">
        <input
          aria-label="6-digit code" inputMode="numeric" autoComplete="one-time-code" maxLength={9}
          value={code} onChange={(e) => setCode(e.target.value)} placeholder="123456"
          className="flex-1 bg-black border border-white/20 px-4 py-3 text-white font-bold tracking-[0.3em]"
        />
        <button disabled={busy} className="bg-brand-primary text-black font-black uppercase tracking-wider px-6 py-3 disabled:opacity-40">
          Confirm
        </button>
      </form>
      {err && <p role="alert" className="text-red-400 text-sm mb-2">{err}</p>}
      <div className="text-sm space-y-2">
        <button type="button" disabled={busy} onClick={() => void send('email')} className="underline disabled:opacity-40">
          Send the code again
        </button>
        {!usePhone ? (
          <p>
            Typed the wrong email?{' '}
            <button type="button" onClick={() => setUsePhone(true)} className="underline">Get a code by text instead</button>
          </p>
        ) : (
          <div className="flex gap-2">
            <input
              aria-label="Mobile number" type="tel" autoComplete="tel" value={phone} onChange={(e) => setPhone(e.target.value)}
              placeholder="(212) 555-0100" className="flex-1 bg-black border border-white/20 px-3 py-2 text-white"
            />
            <button type="button" disabled={busy || !phone.trim()} onClick={() => void send('sms')}
              className="border border-white/30 px-4 py-2 font-bold disabled:opacity-40">
              Text me a code
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
