// /book/:orgSlug — the public booking-request form (mig 20261102130000,
// docs/templates-inbound.md). Anyone can send one while the organization has
// the form switched on. exos_inbound_submit caps the body, rate limits per
// network and email, and drops the hidden `homepage` field's bots.

import { useEffect, useState, type FormEvent } from 'react';
import { useParams } from 'react-router-dom';
import { getInboundForm, submitInbound, type InboundPublicForm } from '../lib/templatesApi';
import { CONTACT_ROLES, emptyInboundForm, inboundErrorMessage, inboundPayload, LINK_KINDS, type InboundForm } from '../lib/inbound';

const FLD = 'bg-white border border-slate-200 rounded px-3 py-2 text-sm text-slate-900 w-full focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
const LABEL = 'block text-[10px] font-black uppercase tracking-widest text-slate-500 mb-1';

export default function BookingRequest() {
  const { orgSlug } = useParams();
  const [form, setForm] = useState<InboundPublicForm | null | undefined>(undefined);
  const [f, setF] = useState<InboundForm>(emptyInboundForm());
  const [date, setDate] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);

  useEffect(() => {
    if (!orgSlug) return;
    getInboundForm(orgSlug).then(setForm).catch(() => setForm(null));
  }, [orgSlug]);

  if (form === undefined) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!form || !orgSlug) return <div className="max-w-xl mx-auto px-4 py-16 text-center text-slate-600">This venue isn't taking booking requests online right now.</div>;
  if (sent) {
    return (
      <div className="max-w-xl mx-auto px-4 py-16 text-center">
        <h1 className="text-2xl font-black text-slate-900 mb-2">Request sent</h1>
        <p className="text-slate-600">Thanks. {form.org_name} will reply to {f.email.trim().toLowerCase()} if it's a fit.</p>
      </div>
    );
  }

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const p = inboundPayload(f);
    if (p.ok === false) { setError(p.error); return; }
    setError('');
    setBusy(true);
    try {
      await submitInbound(orgSlug, p.payload);
      setSent(true);
    } catch (err) {
      setError(inboundErrorMessage(err as { code?: string; message?: string }));
    } finally {
      setBusy(false);
    }
  };
  const set = (patch: Partial<InboundForm>) => setF({ ...f, ...patch });

  return (
    <div className="max-w-2xl mx-auto px-4 py-10">
      <h1 className="text-2xl font-black text-slate-900 mb-1">{form.title}</h1>
      {form.intro && <p className="text-slate-600 mb-6 whitespace-pre-wrap">{form.intro}</p>}
      <form onSubmit={submit} className="grid gap-4 bg-white border border-slate-200 rounded p-5" noValidate>
        <div className="grid gap-4 sm:grid-cols-2">
          <label><span className={LABEL}>Act / artist *</span><input className={FLD} required maxLength={150} value={f.artist_name} onChange={(e) => set({ artist_name: e.target.value })} /></label>
          <label><span className={LABEL}>Your name</span><input className={FLD} maxLength={100} value={f.contact_name} onChange={(e) => set({ contact_name: e.target.value })} /></label>
          <label><span className={LABEL}>Email *</span><input className={FLD} type="email" required maxLength={200} value={f.email} onChange={(e) => set({ email: e.target.value })} /></label>
          <label><span className={LABEL}>You are</span>
            <select className={FLD} value={f.contact_role} onChange={(e) => set({ contact_role: e.target.value })}>
              {CONTACT_ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
            </select></label>
          <label><span className={LABEL}>Phone</span><input className={FLD} type="tel" maxLength={40} value={f.phone} onChange={(e) => set({ phone: e.target.value })} /></label>
          {form.venues.length > 1 && (
            <label><span className={LABEL}>Venue</span>
              <select className={FLD} value={f.venue_id} onChange={(e) => set({ venue_id: e.target.value })}>
                <option value="">Any</option>
                {form.venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
              </select></label>
          )}
          <label><span className={LABEL}>Genres (comma separated)</span><input className={FLD} maxLength={400} value={f.genres} onChange={(e) => set({ genres: e.target.value })} /></label>
          <label><span className={LABEL}>Expected draw</span><input className={FLD} inputMode="numeric" maxLength={7} value={f.expected_draw} onChange={(e) => set({ expected_draw: e.target.value })} /></label>
        </div>
        <fieldset>
          <legend className={LABEL}>Preferred dates</legend>
          <div className="flex gap-2 items-center">
            <input className={`${FLD} max-w-[200px]`} type="date" aria-label="Add a date" value={date} onChange={(e) => setDate(e.target.value)} />
            <button type="button" className="px-3 py-2 border border-slate-200 rounded text-xs font-bold" disabled={!date || f.preferred_dates.length >= 10}
              onClick={() => { if (date && !f.preferred_dates.includes(date)) set({ preferred_dates: [...f.preferred_dates, date].sort() }); setDate(''); }}>Add</button>
            <label className="flex items-center gap-1 text-sm ml-2"><input type="checkbox" checked={f.dates_flexible} onChange={(e) => set({ dates_flexible: e.target.checked })} />Flexible</label>
          </div>
          {f.preferred_dates.length > 0 && (
            <ul className="flex flex-wrap gap-2 mt-2">
              {f.preferred_dates.map((d) => (
                <li key={d}><button type="button" className="text-xs bg-slate-100 rounded px-2 py-1" aria-label={`Remove ${d}`}
                  onClick={() => set({ preferred_dates: f.preferred_dates.filter((x) => x !== d) })}>{d} ×</button></li>
              ))}
            </ul>
          )}
        </fieldset>
        <div className="grid gap-4 sm:grid-cols-2">
          {LINK_KINDS.slice(0, 4).map((k) => (
            <label key={k}><span className={LABEL}>{k}</span><input className={FLD} type="url" placeholder="https://" maxLength={300}
              value={f.links[k] ?? ''} onChange={(e) => set({ links: { ...f.links, [k]: e.target.value } })} /></label>
          ))}
        </div>
        <label><span className={LABEL}>Message</span><textarea className={FLD} rows={5} maxLength={5000} value={f.message} onChange={(e) => set({ message: e.target.value })} /></label>
        {/* Honeypot: hidden from people and screen readers; bots fill it. */}
        <div aria-hidden="true" style={{ position: 'absolute', left: '-10000px', width: 1, height: 1, overflow: 'hidden' }}>
          <label>Homepage<input tabIndex={-1} autoComplete="off" value={f.homepage} onChange={(e) => set({ homepage: e.target.value })} /></label>
        </div>
        {error && <p role="alert" className="text-sm text-red-600">{error}</p>}
        <button type="submit" disabled={busy} className="px-4 py-3 rounded bg-slate-900 text-white text-xs font-black uppercase tracking-widest disabled:opacity-40">
          {busy ? 'Sending…' : `Send to ${form.org_name}`}
        </button>
      </form>
    </div>
  );
}
