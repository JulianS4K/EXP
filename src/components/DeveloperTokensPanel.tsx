// Profile → Developer (mig 20261031130500, docs/developer-platform.md):
// personal access tokens and the apps this user connected.
//
// A token is pinned to one organization and acts as this user: on every
// request its scopes are narrowed to what the user's role there allows now,
// and it is revoked when the user leaves the organization. The plaintext is
// shown once.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Copy, EyeOff, KeyRound, Trash2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { useOrganization } from '../context/OrganizationContext';
import {
  createPersonalToken, disconnectApp, listPersonalTokens, myConnectedApps, revokePersonalToken, sqlMessage,
  type Grant, type PersonalToken,
} from '../lib/developerPlatform';
import { ROLE_SCOPES, type OrgRole } from '../../supabase/functions/_shared/api/credentials.ts';
import { SCOPE_INFO } from '../../supabase/functions/_shared/api/scopes.ts';

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const FLD = 'bg-black border border-white/20 px-3 py-2 text-xs text-white';

export default function DeveloperTokensPanel() {
  const { toast } = useToast();
  const { orgs } = useOrganization();
  const [tokens, setTokens] = useState<PersonalToken[] | null>(null);
  const [grants, setGrants] = useState<Grant[]>([]);
  const [orgId, setOrgId] = useState('');
  const [name, setName] = useState('');
  const [scopes, setScopes] = useState<string[]>(['events:read']);
  const [days, setDays] = useState<string>('90');
  const [fresh, setFresh] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    listPersonalTokens().then(setTokens).catch(() => setTokens([]));
    myConnectedApps().then(setGrants).catch(() => setGrants([]));
  }, []);
  useEffect(load, [load]);
  useEffect(() => { if (!orgId && orgs.length) setOrgId(orgs[0].org.id); }, [orgs, orgId]);

  const role = orgs.find((o) => o.org.id === orgId)?.membership.role as OrgRole | undefined;
  const allowed = useMemo(() => (role ? ROLE_SCOPES[role] : []), [role]);
  const orgName = (id: string) => orgs.find((o) => o.org.id === id)?.org.name ?? 'an organization';

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast({ kind: 'success', message: ok });
      load();
    } catch (e) {
      toast({ kind: 'error', message: sqlMessage(e) });
    } finally {
      setBusy(false);
    }
  };

  if (orgs.length === 0 && (tokens?.length ?? 0) === 0 && grants.length === 0) return null;

  return (
    <div className="bg-[#111] border border-white/10 p-8 space-y-6" id="developer">
      <div className="flex items-center gap-2">
        <KeyRound className="w-5 h-5 text-brand-primary" aria-hidden="true" />
        <h2 className="disp text-2xl tracking-tight uppercase">Developer</h2>
      </div>
      <p className="type text-[12px] text-white/50">
        Personal access tokens let your scripts and AI agents use the{' '}
        <Link to="/developers" className="text-brand-primary hover:underline">Exos API</Link> and the MCP server as you,
        in one organization, never beyond your role there. Building an app for other organizers?{' '}
        <Link to="/developers/apps" className="text-brand-primary hover:underline">Register an OAuth app</Link>.
      </p>

      {fresh && (
        <div className="bg-brand-primary/10 border border-brand-primary/40 p-3 space-y-2">
          <p className="text-xs text-white">Copy your token now. It won't be shown again.</p>
          <div className="flex items-center gap-2">
            <code className="text-[11px] text-brand-primary break-all flex-1">{fresh}</code>
            <button type="button" className={BTN} onClick={() => navigator.clipboard?.writeText(fresh)} aria-label="Copy token"><Copy className="w-3 h-3" /></button>
            <button type="button" className={BTN} onClick={() => setFresh(null)} aria-label="Hide token"><EyeOff className="w-3 h-3" /></button>
          </div>
        </div>
      )}

      {orgs.length > 0 && (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2 items-end">
            <label className="flex flex-col gap-1">
              <span className="type text-[10px] uppercase tracking-widest text-white/50">Organization</span>
              <select className={FLD} value={orgId} onChange={(e) => { setOrgId(e.target.value); setScopes(['events:read']); }}>
                {orgs.map((o) => <option key={o.org.id} value={o.org.id}>{o.org.name} ({o.membership.role})</option>)}
              </select>
            </label>
            <label className="flex flex-col gap-1 flex-1 min-w-[10rem]">
              <span className="type text-[10px] uppercase tracking-widest text-white/50">Name</span>
              <input className={FLD} value={name} maxLength={80} placeholder="Nightly report" onChange={(e) => setName(e.target.value)} />
            </label>
            <label className="flex flex-col gap-1">
              <span className="type text-[10px] uppercase tracking-widest text-white/50">Expires</span>
              <select className={FLD} value={days} onChange={(e) => setDays(e.target.value)}>
                <option value="30">30 days</option><option value="90">90 days</option>
                <option value="365">1 year</option><option value="">Never</option>
              </select>
            </label>
          </div>
          <div className="grid sm:grid-cols-2 gap-1.5">
            {allowed.map((s) => (
              <label key={s} className="flex items-start gap-2 text-xs text-white/80">
                <input type="checkbox" className="mt-0.5 accent-brand-primary" checked={scopes.includes(s)}
                  onChange={() => setScopes((cur) => (cur.includes(s) ? cur.filter((x) => x !== s) : [...cur, s]))} />
                <span>{SCOPE_INFO[s].label} <code className="text-[10px] text-white/40">{s}</code></span>
              </label>
            ))}
          </div>
          <button type="button" className={BTN} disabled={busy || !orgId || scopes.length === 0}
            onClick={() => run(async () => {
              const r = await createPersonalToken(orgId, name.trim() || 'Token', scopes, days ? Number(days) : null);
              setFresh(r.token);
              setName('');
            }, 'Token created')}>
            Create token
          </button>
        </div>
      )}

      {tokens && tokens.length > 0 && (
        <ul className="space-y-2">
          {tokens.map((t) => (
            <li key={t.id} className="bg-white/5 border border-white/10 px-3 py-2 flex items-center gap-2">
              <div className="flex-1 min-w-0">
                <p className="text-sm text-white">{t.name} <span className="text-white/40 text-xs">· {orgName(t.org_id)}</span></p>
                <p className="text-[11px] text-white/40">
                  <code>{t.key_prefix}…</code> · {t.scopes.join(', ')} ·{' '}
                  {t.expires_at ? `expires ${new Date(t.expires_at).toLocaleDateString()}` : 'no expiry'}
                  {t.last_used_at ? ` · last used ${new Date(t.last_used_at).toLocaleString()}` : ''}
                </p>
              </div>
              <button type="button" className={BTN} disabled={busy} aria-label={`Revoke ${t.name}`}
                onClick={() => run(() => revokePersonalToken(t.id), 'Revoked')}>
                <Trash2 className="w-3 h-3" />
              </button>
            </li>
          ))}
        </ul>
      )}

      {grants.length > 0 && (
        <div className="space-y-2">
          <p className="type text-[10px] uppercase tracking-widest text-white/50">Connected apps</p>
          <ul className="space-y-2">
            {grants.map((g) => (
              <li key={g.grant_id} className="bg-white/5 border border-white/10 px-3 py-2 flex items-center gap-2">
                <div className="flex-1 min-w-0">
                  <p className="text-sm text-white">{g.app.name} <span className="text-white/40 text-xs">· {g.org_name}</span></p>
                  <p className="text-[11px] text-white/40">{g.scopes.join(', ')}</p>
                </div>
                <button type="button" className={BTN} disabled={busy}
                  onClick={() => run(() => disconnectApp(g.grant_id), 'Disconnected')}>
                  Disconnect
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
