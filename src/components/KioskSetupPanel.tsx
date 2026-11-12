// Kiosk mode setup (mig 20261113100000, docs/pos.md "Kiosk mode"), in the
// door app's Sell tab for owners and managers: mark a register device as this
// event's kiosk (its card reader, a printer, the admin PIN), start kiosk mode
// on this screen, end a kiosk's session or turn it off. The rules are in SQL
// (exos_pos_kiosk_*); this panel only calls them.

import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Monitor } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useToast } from '../context/ToastContext';
import {
  addKioskDevice, configureKiosk, endKioskSession, KIOSK_PIN_RULE, kioskErrorText, listKioskDevices, startKioskHere, turnOffKiosk,
  type KioskDevice,
} from '../lib/kioskApi';
import type { WalkupReader } from '../lib/posWalkup';

const BIG = 'min-h-[48px] px-4 rounded-xl text-sm font-black uppercase tracking-widest';
const INPUT = 'w-full min-h-[48px] border border-slate-300 rounded-xl px-3 text-base bg-white';

export default function KioskSetupPanel({ eventId, readers, cardOn }: { eventId: string; readers: WalkupReader[]; cardOn: boolean }) {
  const { toast } = useToast();
  const navigate = useNavigate();
  const [orgId, setOrgId] = useState<string | null>(null);
  const [devices, setDevices] = useState<KioskDevice[]>([]);
  const [deviceId, setDeviceId] = useState('');
  const [newName, setNewName] = useState('Gate kiosk');
  const [readerId, setReaderId] = useState('');
  const [pin, setPin] = useState('');
  const [printer, setPrinter] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const { data } = await supabase.from('exos_events').select('org_id').eq('id', eventId).maybeSingle();
      const org = (data as { org_id?: string } | null)?.org_id ?? null;
      setOrgId(org);
      if (org) setDevices(await listKioskDevices(org));
    } catch (e) {
      toast({ kind: 'error', message: kioskErrorText(e) });
    }
  }, [eventId, toast]);
  useEffect(() => { void load(); }, [load]);

  const device = devices.find((d) => d.id === deviceId) ?? null;
  useEffect(() => {
    if (!device) return;
    setReaderId(device.kiosk?.reader_device_id ?? readers[0]?.device_id ?? '');
    setPrinter(device.kiosk?.printer ?? false);
    setPin('');
  }, [device, readers]);

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast({ kind: 'success', message: ok });
      await load();
    } catch (e) {
      toast({ kind: 'error', message: kioskErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const add = () => run(async () => {
    if (!orgId) return;
    const id = await addKioskDevice(orgId, newName);
    setDeviceId(id);
  }, 'Device added.');

  const save = () => run(() => configureKiosk({ deviceId, eventId, readerId: readerId || null, pin, printer }), 'Kiosk saved.');

  const start = async () => {
    if (!device?.kiosk || device.kiosk.event_id !== eventId) return;
    if (!window.confirm('Start kiosk mode on this screen? You will be signed out here; the admin PIN leaves kiosk mode.')) return;
    setBusy(true);
    try {
      await startKioskHere(device.id);
      navigate('/kiosk', { replace: true });
    } catch (e) {
      toast({ kind: 'error', message: kioskErrorText(e) });
      setBusy(false);
    }
  };

  const here = devices.filter((d) => d.kiosk?.event_id === eventId);

  return (
    <section aria-labelledby="kiosk-h" className="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
      <h2 id="kiosk-h" className="text-sm font-black uppercase tracking-widest text-slate-500 flex items-center gap-2">
        <Monitor className="w-4 h-4" aria-hidden="true" /> Kiosk mode
      </h2>
      <p className="text-xs text-slate-500">
        A self-serve screen that sells this event's public tickets by card on its own reader. No cash, comps or refunds there.
        {!cardOn && ' Card payments are off, so a kiosk shows "unavailable" for now.'}
      </p>
      {here.length > 0 && (
        <ul className="space-y-2">
          {here.map((d) => (
            <li key={d.id} className="rounded-xl border border-slate-200 p-3 flex flex-wrap items-center gap-2">
              <span className="flex-1 min-w-0 font-bold truncate">{d.name}{d.live ? ' · live' : ''}</span>
              {d.live && (
                <button type="button" disabled={busy} onClick={() => void run(() => endKioskSession(d.id), 'Kiosk session ended.')}
                  className={`${BIG} border border-slate-300`}>End session</button>
              )}
              <button type="button" disabled={busy} onClick={() => void run(() => turnOffKiosk(d.id), 'Kiosk turned off.')}
                className={`${BIG} border border-rose-300 text-rose-700`}>Turn off</button>
            </li>
          ))}
        </ul>
      )}
      <label className="block text-sm">
        <span className="block font-bold mb-1">Device</span>
        <select value={deviceId} onChange={(e) => setDeviceId(e.target.value)} className={INPUT}>
          <option value="">Pick a device</option>
          {devices.map((d) => (
            <option key={d.id} value={d.id}>{d.name}{d.kiosk ? (d.kiosk.event_id === eventId ? ' (kiosk here)' : ' (kiosk elsewhere)') : ''}</option>
          ))}
        </select>
      </label>
      <div className="grid grid-cols-[1fr_auto] gap-2 items-end">
        <label className="text-sm">
          <span className="block font-bold mb-1">Or add this screen</span>
          <input value={newName} maxLength={80} onChange={(e) => setNewName(e.target.value)} className={INPUT} />
        </label>
        <button type="button" disabled={busy || !orgId} onClick={() => void add()} className={`${BIG} border border-slate-300`}>Add</button>
      </div>
      {device && (
        <div className="grid gap-2">
          <label className="block text-sm">
            <span className="block font-bold mb-1">Card reader</span>
            <select value={readerId} onChange={(e) => setReaderId(e.target.value)} className={INPUT}>
              <option value="">None yet</option>
              {readers.map((r) => <option key={r.device_id} value={r.device_id}>{r.label}</option>)}
            </select>
          </label>
          <label className="block text-sm">
            <span className="block font-bold mb-1">Admin PIN{device.kiosk ? ' (leave empty to keep it)' : ''}</span>
            <input type="password" inputMode="numeric" autoComplete="new-password" maxLength={12} value={pin}
              onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))} className={INPUT} aria-describedby="kiosk-pin-rule" />
            <span id="kiosk-pin-rule" className="block text-xs text-slate-500 mt-1">{KIOSK_PIN_RULE}.</span>
          </label>
          <label className="flex items-center gap-3 text-sm min-h-[48px]">
            <input type="checkbox" checked={printer} onChange={(e) => setPrinter(e.target.checked)} className="w-5 h-5" />
            A ticket printer is attached
          </label>
          <button type="button" disabled={busy || (!device.kiosk && pin.length < 6)} onClick={() => void save()}
            className={`${BIG} w-full bg-slate-900 text-white disabled:opacity-50`}>Save kiosk</button>
          {device.kiosk?.event_id === eventId && (
            <button type="button" disabled={busy} onClick={() => void start()} className={`${BIG} w-full border-2 border-slate-900`}>
              Start kiosk mode on this screen
            </button>
          )}
        </div>
      )}
    </section>
  );
}
