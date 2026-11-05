// Org settings → Integrations → Import from DICE (mig 20261106100000;
// docs/dice-coverage.md). Owners and managers paste the API token from MIO
// (DICE's partner dashboard), preview what an import would bring in (a dry
// run: nothing is written), then import. DICE events arrive as drafts sold
// on DICE (Exos never sells DICE's inventory), ticket holders onto each
// event's DICE door list (their DICE barcode scans at the Exos door), and
// fans: only those who opted in to partner marketing on DICE join the email
// list. Exos only reads DICE.

import { useCallback, useEffect, useRef, useState } from 'react';
import { CheckCircle2, AlertTriangle, Loader2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  cleanDiceToken, connectDice, disconnectDice, fetchDiceStatus, previewText, syncDice, syncStatusText,
  type DiceStatus, type DiceSyncResult,
} from '../lib/diceImport';

const BTN = 'px-3 py-1.5 rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50';
const FLD = 'w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

type Busy = null | 'connect' | 'disconnect' | 'preview' | 'import';

export default function DiceImportCard({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [status, setStatus] = useState<DiceStatus | null | undefined>(undefined);
  const [token, setToken] = useState('');
  const [editing, setEditing] = useState(false);
  const [preview, setPreview] = useState<DiceSyncResult | null>(null);
  const [busy, setBusy] = useState<Busy>(null);
  const alive = useRef(true);

  const load = useCallback(async () => {
    try {
      const s = await fetchDiceStatus(orgId);
      if (alive.current) setStatus(s);
    } catch {
      if (alive.current) setStatus(null);
    }
  }, [orgId]);

  useEffect(() => {
    alive.current = true;
    void load();
    return () => { alive.current = false; };
  }, [load]);

  const run = async (kind: Busy, fn: () => Promise<void>) => {
    setBusy(kind);
    try {
      await fn();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      if (alive.current) setBusy(null);
      void load();
    }
  };

  const connect = () => run('connect', async () => {
    const t = cleanDiceToken(token);
    if (!t) throw new Error("That doesn't look like a DICE API token. Copy it again from MIO.");
    const r = await connectDice(orgId, t);
    setToken('');
    setEditing(false);
    setPreview(null);
    toast({ kind: 'success', message: `Connected${r.account_name ? ` to ${r.account_name}` : ''}. Preview the import next.` });
  });

  const disconnect = () => {
    if (!window.confirm('Disconnect DICE? Exos deletes its DICE token. Imported events, ticket holders and fans stay.')) return;
    void run('disconnect', async () => {
      await disconnectDice(orgId);
      setPreview(null);
      toast({ kind: 'success', message: 'Disconnected. Exos deleted its DICE token.' });
    });
  };

  const dryRun = () => run('preview', async () => {
    const r = await syncDice(orgId, true);
    setPreview(r);
  });

  const importNow = () => run('import', async () => {
    const r = await syncDice(orgId, false);
    setPreview(null);
    if (r.result === 'error') throw new Error(r.error ?? 'The import failed.');
    toast({
      kind: 'success',
      message: r.result === 'partial' ? 'Imported a first batch. Run it again (or let the schedule) to continue.' : 'Imported from DICE.',
    });
  });

  if (status === undefined) {
    return <li className="border border-slate-200 rounded-xl p-4 text-xs text-slate-400">Checking DICE…</li>;
  }
  if (status === null) return null; // not deployed, or not an owner / manager of this org

  const connected = status.connected;
  const showForm = !connected || editing || status.status === 'error';
  return (
    <li className="border border-slate-200 rounded-xl p-4" data-testid="dice-import-card">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="text-sm font-bold text-slate-900">Import from DICE</p>
          <p className="text-[11px] text-slate-500 mt-0.5">
            Bring your DICE events, ticket holders and fans to Exos. Events arrive as drafts still sold on DICE, holders’ DICE
            barcodes scan at the Exos door, and only fans who opted in to partner marketing on DICE join your email list.
            Exos only reads DICE.
          </p>
        </div>
        {connected && status.status !== 'error' && (
          <span className="inline-flex items-center gap-1 text-[10px] font-black uppercase tracking-widest rounded px-2 py-0.5 bg-emerald-50 text-emerald-700">
            <CheckCircle2 className="w-3 h-3" aria-hidden="true" /> Connected
          </span>
        )}
        {status.status === 'error' && (
          <span className="inline-flex items-center gap-1 text-[10px] font-black uppercase tracking-widest rounded px-2 py-0.5 bg-amber-50 text-amber-700">
            <AlertTriangle className="w-3 h-3" aria-hidden="true" /> Reconnect
          </span>
        )}
      </div>

      <p className="text-[11px] text-slate-500 mt-2" aria-live="polite" data-testid="dice-sync-status">
        {connected && status.accountName ? `${status.accountName} · ` : ''}{syncStatusText(status)}
      </p>

      {showForm && (
        <div className="mt-3 space-y-2">
          <label className="block text-[10px] font-black text-slate-500 uppercase tracking-widest" htmlFor={`dice-token-${orgId}`}>
            DICE API token
          </label>
          <input id={`dice-token-${orgId}`} className={FLD} type="password" value={token} autoComplete="new-password" spellCheck={false}
            placeholder="Paste the token from MIO" onChange={(e) => setToken(e.target.value)} />
          <p className="text-[11px] text-slate-400">
            Generate an API token in MIO, DICE’s partner dashboard (mio.dice.fm), and paste it here. Exos checks it with DICE
            and stores it encrypted; it is never shown again.
          </p>
          <div className="flex flex-wrap gap-2">
            <button type="button" onClick={() => void connect()} disabled={busy !== null || !token.trim()}
              className={`${BTN} bg-tm-blue text-white inline-flex items-center gap-1`}>
              {busy === 'connect' && <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />}
              {connected ? 'Replace token' : 'Connect DICE'}
            </button>
            {editing && (
              <button type="button" onClick={() => { setEditing(false); setToken(''); }} disabled={busy !== null}
                className={`${BTN} border border-slate-200 text-slate-700`}>Cancel</button>
            )}
          </div>
        </div>
      )}

      {connected && status.status !== 'error' && (
        <div className="mt-3 flex flex-wrap gap-2">
          <button type="button" onClick={() => void dryRun()} disabled={busy !== null || status.syncing}
            className={`${BTN} border border-slate-200 text-slate-700 inline-flex items-center gap-1`}>
            {busy === 'preview' && <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />}
            Preview
          </button>
          <button type="button" onClick={() => void importNow()} disabled={busy !== null || status.syncing}
            className={`${BTN} bg-tm-blue text-white inline-flex items-center gap-1`}>
            {busy === 'import' && <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />}
            {status.lastOkAt ? 'Sync now' : 'Import'}
          </button>
          {!editing && (
            <button type="button" onClick={() => setEditing(true)} disabled={busy !== null}
              className={`${BTN} border border-slate-200 text-slate-700`}>Change token</button>
          )}
          <button type="button" onClick={disconnect} disabled={busy !== null}
            className={`${BTN} border border-rose-200 text-rose-600`}>Disconnect</button>
        </div>
      )}
      {status.status === 'error' && (
        <div className="mt-2">
          <button type="button" onClick={disconnect} disabled={busy !== null}
            className={`${BTN} border border-rose-200 text-rose-600`}>Disconnect</button>
        </div>
      )}

      {preview && (
        <div className="mt-3 rounded-lg bg-slate-50 border border-slate-200 p-3 text-[11px] text-slate-600" data-testid="dice-preview">
          <p className="font-bold text-slate-800 mb-1">Preview (nothing imported yet)</p>
          <p>{previewText(preview)}</p>
          {preview.error && <p className="text-rose-600 mt-1">{preview.error}</p>}
        </div>
      )}

      {status.runs.length > 0 && (
        <details className="mt-3">
          <summary className="text-[10px] font-black uppercase tracking-widest text-slate-400 cursor-pointer">Recent runs</summary>
          <ul className="mt-2 space-y-1 text-[11px] text-slate-500">
            {status.runs.map((r) => (
              <li key={r.id}>
                {r.startedAt ? new Date(r.startedAt).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : ''}:{' '}
                {r.dryRun ? 'preview' : r.kind === 'full' ? 'import' : 'sync'} ({r.trigger}) · {r.status}
                {r.error ? ` · ${r.error}` : ''}
              </li>
            ))}
          </ul>
        </details>
      )}
    </li>
  );
}
