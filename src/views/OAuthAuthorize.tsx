// /oauth/authorize — the OAuth consent screen (mig 20261031130500,
// docs/developer-platform.md). exos-oauth's GET /authorize sends the browser
// here with the app's query. The user signs in, sees the app, where it will
// send them back, the scopes, and their organizations with what their role
// there can grant; picks one and allows or denies.
//
// A bad client_id or an unregistered redirect URI is shown here and never
// redirected to. Other problems, and Deny, go back to the app as error=….
// The code is minted by exos_oauth_authorize_approve (the user's session) and
// handed to the app in the redirect.

import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useLocation } from 'react-router-dom';
import { ShieldCheck, TriangleAlert } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { authorizeApprove, authorizeInfo, sqlMessage, type AuthorizeInfo } from '../lib/developerPlatform';
import { parseAuthorizeQuery, withParams } from '../../supabase/functions/_shared/api/credentials.ts';
import { isScope, SCOPE_INFO } from '../../supabase/functions/_shared/api/scopes.ts';

const BTN = 'px-5 py-2 text-xs font-black uppercase tracking-widest border disabled:opacity-40';

export default function OAuthAuthorize() {
  const { user, openAuthModal } = useAuth();
  const location = useLocation();
  const parsed = useMemo(() => parseAuthorizeQuery(new URLSearchParams(location.search)), [location.search]);
  const [info, setInfo] = useState<AuthorizeInfo | null>(null);
  const [orgId, setOrgId] = useState('');
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);

  // A shape problem the app should hear about goes straight back.
  useEffect(() => {
    if (!parsed.ok && parsed.redirect) {
      const q = new URLSearchParams(location.search);
      window.location.replace(withParams(q.get('redirect_uri')!, {
        error: parsed.error, error_description: parsed.description, state: q.get('state'),
      }));
    }
  }, [parsed, location.search]);

  useEffect(() => {
    if (!user || !parsed.ok) return;
    authorizeInfo(parsed.req.clientId, parsed.req.redirectUri, parsed.req.scope)
      .then((i) => {
        if (!i.ok && i.redirect_ok) {
          window.location.replace(withParams(parsed.req.redirectUri, {
            error: i.error, error_description: i.error_description, state: parsed.req.state,
          }));
          return;
        }
        setInfo(i);
        const first = i.orgs?.find((o) => o.grantable.length > 0);
        if (first) setOrgId(first.org_id);
      })
      .catch((e) => setFailure(sqlMessage(e)));
  }, [user, parsed]);

  if (!parsed.ok && !parsed.redirect) return <Problem text={parsed.description} />;
  if (!parsed.ok) return null;
  if (!user) {
    return (
      <Shell>
        <p className="text-sm text-white/70">Sign in to Exos to connect an app to your organization.</p>
        <button type="button" className={`${BTN} border-brand-primary text-brand-primary`} onClick={openAuthModal}>Sign in</button>
      </Shell>
    );
  }
  if (failure) return <Problem text={failure} />;
  if (!info) return <Shell><p className="text-sm text-white/50">Checking the app…</p></Shell>;
  if (!info.ok) return <Problem text={info.error_description ?? 'This app can\'t be connected.'} />;

  const org = info.orgs?.find((o) => o.org_id === orgId);
  const req = parsed.req;
  const back = (params: Record<string, string | undefined>) => window.location.assign(withParams(req.redirectUri, { ...params, state: req.state }));

  return (
    <Shell>
      <div className="flex items-center gap-3">
        {info.app?.logo_url && <img src={info.app.logo_url} alt="" className="w-10 h-10 object-cover" />}
        <div>
          <h1 className="text-lg font-black">{info.app?.name} wants to use Exos as you</h1>
          {info.app?.verified === false && (
            <p className="text-[11px] text-amber-400 flex items-center gap-1">
              <TriangleAlert className="w-3 h-3" /> Unverified: this app registered itself. Only continue if you trust it.
            </p>
          )}
          <p className="text-[11px] text-white/40">It will send you back to <strong>{info.redirect_host}</strong>.</p>
        </div>
      </div>

      <label className="block space-y-1">
        <span className="text-[10px] uppercase tracking-widest text-white/50">Organization</span>
        <select className="w-full bg-black border border-white/20 px-3 py-2 text-sm" value={orgId} onChange={(e) => setOrgId(e.target.value)}>
          {(info.orgs ?? []).map((o) => (
            <option key={o.org_id} value={o.org_id} disabled={o.grantable.length === 0}>
              {o.name} ({o.role}){o.grantable.length === 0 ? ': nothing your role can grant' : ''}
            </option>
          ))}
        </select>
      </label>

      <div className="space-y-1">
        <p className="text-[10px] uppercase tracking-widest text-white/50">It will be able to</p>
        <ul className="space-y-1">
          {(info.scopes ?? []).map((s) => {
            const granted = org?.grantable.includes(s) ?? false;
            return (
              <li key={s} className={`text-xs flex items-start gap-2 ${granted ? 'text-white' : 'text-white/30 line-through'}`}>
                <ShieldCheck className="w-3 h-3 mt-0.5 shrink-0" />
                {isScope(s) ? SCOPE_INFO[s].label : s}
              </li>
            );
          })}
        </ul>
        <p className="text-[11px] text-white/40">Never more than your role allows; if your role changes, so does the app's access. Disconnect it any time in your profile.</p>
      </div>

      <div className="flex gap-3">
        <button type="button" className={`${BTN} border-brand-primary bg-brand-primary text-black`} disabled={busy || !org || org.grantable.length === 0}
          onClick={async () => {
            setBusy(true);
            try {
              const code = await authorizeApprove({
                clientId: req.clientId, redirectUri: req.redirectUri, scope: req.scope, orgId,
                codeChallenge: req.codeChallenge, codeChallengeMethod: req.codeChallengeMethod, resource: req.resource,
              });
              back({ code });
            } catch (e) {
              setFailure(sqlMessage(e));
              setBusy(false);
            }
          }}>
          Allow
        </button>
        <button type="button" className={`${BTN} border-white/20 text-white/70`} disabled={busy}
          onClick={() => back({ error: 'access_denied', error_description: 'The user denied the request.' })}>
          Deny
        </button>
      </div>
    </Shell>
  );
}

function Shell({ children }: { children: ReactNode }) {
  return <div className="max-w-md mx-auto px-4 py-16 text-white"><div className="bg-[#111] border border-white/10 p-6 space-y-5">{children}</div></div>;
}

function Problem({ text }: { text: string }) {
  return (
    <Shell>
      <p className="text-sm text-white flex items-start gap-2"><TriangleAlert className="w-4 h-4 text-amber-400 shrink-0" /> {text}</p>
      <p className="text-[11px] text-white/40">Nothing was connected. Go back to the app and try again, or contact its developer.</p>
    </Shell>
  );
}
