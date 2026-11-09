// /developers/apps — register OAuth apps (mig 20261031130500,
// docs/developer-platform.md). A confidential app (a server) gets a client
// secret, shown once and rotatable; a public app (browser, mobile, CLI, an AI
// client) has none and must use PKCE. Deleting an app revokes every grant and
// token it has.

import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Copy, EyeOff, Trash2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { createApp, deleteApp, listMyApps, rotateAppSecret, sqlMessage, type OAuthApp } from '../lib/developerPlatform';
import { redirectUriProblem } from '../../supabase/functions/_shared/api/credentials.ts';
import { SCOPES, SCOPE_INFO } from '../../supabase/functions/_shared/api/scopes.ts';

const BTN = 'text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const FLD = 'w-full bg-black border border-white/20 px-3 py-2 text-xs text-white';

export default function DeveloperApps() {
  const { user, openAuthModal } = useAuth();
  const { toast } = useToast();
  const [apps, setApps] = useState<OAuthApp[] | null>(null);
  const [name, setName] = useState('');
  const [uris, setUris] = useState('');
  const [scopes, setScopes] = useState<string[]>(['events:read']);
  const [type, setType] = useState<'confidential' | 'public'>('confidential');
  const [homepage, setHomepage] = useState('');
  const [secret, setSecret] = useState<{ clientId: string; secret: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => { listMyApps().then(setApps).catch(() => setApps([])); }, []);
  useEffect(() => { if (user) load(); }, [user, load]);

  if (!user) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-16 text-white space-y-4">
        <h1 className="disp text-3xl uppercase">OAuth apps</h1>
        <p className="text-white/60 text-sm">Sign in to register apps that connect to Exos organizations.</p>
        <button type="button" className={BTN} onClick={openAuthModal}>Sign in</button>
      </div>
    );
  }

  const uriList = uris.split(/\s+/).map((u) => u.trim()).filter(Boolean);
  const uriProblem = uriList.map((u) => redirectUriProblem(u) && `${u} ${redirectUriProblem(u)}`).find(Boolean);

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

  return (
    <div className="max-w-3xl mx-auto px-4 py-12 text-white space-y-8">
      <div className="space-y-2">
        <h1 className="disp text-3xl uppercase">OAuth apps</h1>
        <p className="text-sm text-white/60">
          Let organizers connect your product to their Exos organization: they sign in, pick an organization and
          approve the scopes you ask for. Your app then calls the <Link to="/developers" className="text-brand-primary hover:underline">Exos API</Link> or
          the MCP server with an access token (one hour) and a refresh token (60 days, single use). Authorization code
          flow with PKCE; redirect URIs must match exactly.
        </p>
      </div>

      {secret && (
        <div className="bg-brand-primary/10 border border-brand-primary/40 p-3 space-y-2">
          <p className="text-xs">Client secret for <code>{secret.clientId}</code>. Copy it now; it won't be shown again.</p>
          <div className="flex items-center gap-2">
            <code className="text-[11px] text-brand-primary break-all flex-1">{secret.secret}</code>
            <button type="button" className={BTN} onClick={() => navigator.clipboard?.writeText(secret.secret)} aria-label="Copy secret"><Copy className="w-3 h-3" /></button>
            <button type="button" className={BTN} onClick={() => setSecret(null)} aria-label="Hide secret"><EyeOff className="w-3 h-3" /></button>
          </div>
        </div>
      )}

      <section className="bg-[#111] border border-white/10 p-6 space-y-3">
        <h2 className="text-sm font-black uppercase tracking-widest">Register an app</h2>
        <input className={FLD} placeholder="App name" value={name} maxLength={80} onChange={(e) => setName(e.target.value)} />
        <input className={FLD} placeholder="Homepage (optional)" value={homepage} onChange={(e) => setHomepage(e.target.value)} />
        <textarea className={FLD} rows={2} placeholder="Redirect URIs, one per line (https, or http://localhost)" value={uris}
          onChange={(e) => setUris(e.target.value)} />
        {uriProblem && <p className="text-[11px] text-amber-400">{uriProblem}</p>}
        <div className="flex gap-4 text-xs">
          <label className="flex items-center gap-2"><input type="radio" checked={type === 'confidential'} onChange={() => setType('confidential')} /> Server (client secret)</label>
          <label className="flex items-center gap-2"><input type="radio" checked={type === 'public'} onChange={() => setType('public')} /> Browser, mobile or CLI (PKCE only)</label>
        </div>
        <div className="grid sm:grid-cols-2 gap-1.5">
          {SCOPES.map((s) => (
            <label key={s} className="flex items-start gap-2 text-xs text-white/80" title={SCOPE_INFO[s].description}>
              <input type="checkbox" className="mt-0.5 accent-brand-primary" checked={scopes.includes(s)}
                onChange={() => setScopes((cur) => (cur.includes(s) ? cur.filter((x) => x !== s) : [...cur, s]))} />
              <span>{SCOPE_INFO[s].label} <code className="text-[10px] text-white/40">{s}</code></span>
            </label>
          ))}
        </div>
        <button type="button" className={BTN} disabled={busy || !name.trim() || uriList.length === 0 || !!uriProblem || scopes.length === 0}
          onClick={() => run(async () => {
            const a = await createApp({ name: name.trim(), redirectUris: uriList, scopes, clientType: type, homepageUrl: homepage.trim() });
            if (a.client_secret) setSecret({ clientId: a.client_id, secret: a.client_secret });
            setName(''); setUris('');
          }, 'App registered')}>
          Register
        </button>
      </section>

      <section className="space-y-2">
        {(apps ?? []).map((a) => (
          <div key={a.client_id} className="bg-white/5 border border-white/10 px-4 py-3 space-y-1">
            <div className="flex items-center gap-2">
              <p className="flex-1 text-sm">{a.name} <span className="text-white/40 text-xs">· {a.client_type}</span></p>
              {a.client_type === 'confidential' && (
                <button type="button" className={BTN} disabled={busy}
                  onClick={() => run(async () => setSecret({ clientId: a.client_id, secret: (await rotateAppSecret(a.client_id)).client_secret }), 'New secret issued')}>
                  Rotate secret
                </button>
              )}
              <button type="button" className={BTN} disabled={busy} aria-label={`Delete ${a.name}`}
                onClick={() => { if (window.confirm(`Delete ${a.name}? Every organization that connected it is disconnected.`)) run(() => deleteApp(a.client_id), 'Deleted'); }}>
                <Trash2 className="w-3 h-3" />
              </button>
            </div>
            <p className="text-[11px] text-white/50">client_id <code>{a.client_id}</code>{a.secret_prefix ? <> · secret <code>{a.secret_prefix}…</code></> : null}</p>
            <p className="text-[11px] text-white/40">{a.redirect_uris.join(' · ')}</p>
            <p className="text-[11px] text-white/40">{a.scopes.join(', ')}</p>
          </div>
        ))}
      </section>
    </div>
  );
}
