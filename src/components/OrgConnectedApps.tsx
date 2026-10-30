// Org settings → Connected apps (mig 20261031130500, docs/developer-platform.md).
// Owners see every OAuth app a member connected to the organization, who
// connected it and with which scopes, and can disconnect it (the grant and
// every token issued under it are revoked at once).

import { useCallback, useEffect, useState } from 'react';
import { PlugZap } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { disconnectApp, orgConnectedApps, sqlMessage, type Grant } from '../lib/developerPlatform';

const BTN = 'text-[11px] font-black uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';

export default function OrgConnectedApps({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<Grant[] | null>(null);
  const [busy, setBusy] = useState(false);
  const load = useCallback(() => {
    orgConnectedApps(orgId).then(setRows).catch(() => setRows([]));
  }, [orgId]);
  useEffect(load, [load]);

  return (
    <fieldset className="bg-[#111] rounded-2xl border border-white/10 p-5 space-y-3">
      <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">Connected apps</legend>
      <p className="text-xs text-white/40 flex items-start gap-2">
        <PlugZap className="w-4 h-4 text-brand-primary shrink-0" aria-hidden="true" />
        Apps and AI agents your members connected with OAuth. Each acts as the member who approved it, never beyond
        that member's current role.
      </p>
      {rows === null ? (
        <p className="text-xs text-white/40">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-xs text-white/40">No apps are connected.</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((g) => (
            <li key={g.grant_id} className="bg-white/5 border border-white/10 px-3 py-2 flex flex-wrap items-center gap-2">
              <div className="flex-1 min-w-0">
                <p className="text-sm text-white">
                  {g.app.name}
                  {!g.app.verified && <span className="ml-2 text-[10px] uppercase tracking-widest text-amber-400">unverified</span>}
                </p>
                <p className="text-[11px] text-white/40">
                  {g.user_email ?? g.user_id} · {g.scopes.join(', ')} ·{' '}
                  {g.last_used_at ? `last used ${new Date(g.last_used_at).toLocaleString()}` : 'not used yet'}
                </p>
              </div>
              <button type="button" className={BTN} disabled={busy}
                onClick={async () => {
                  if (!window.confirm(`Disconnect ${g.app.name} for ${g.user_email ?? 'this member'}?`)) return;
                  setBusy(true);
                  try {
                    await disconnectApp(g.grant_id);
                    toast({ kind: 'success', message: 'Disconnected' });
                    load();
                  } catch (e) {
                    toast({ kind: 'error', message: sqlMessage(e) });
                  } finally {
                    setBusy(false);
                  }
                }}>
                Disconnect
              </button>
            </li>
          ))}
        </ul>
      )}
    </fieldset>
  );
}
