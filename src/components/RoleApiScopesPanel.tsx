// Org settings → API permissions (mig 20261104180000, docs/org-access.md).
// A role × scope table: what each role's API keys and personal / OAuth
// tokens may carry in this organization. The owner ticks boxes; scopes above
// a role's ceiling (what its dashboard permissions allow) are greyed out and
// can never be given. Saving applies at once to every existing key and
// token of that role. Other members see the table read-only.

import { Fragment, useCallback, useEffect, useState } from 'react';
import { KeyRound } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { SCOPE_INFO, type Scope } from '../../supabase/functions/_shared/api/scopes.ts';
import { getRoleScopes, resetRoleScopes, setRoleScopes, shownScopes, toggleScope, type RoleScopesView } from '../lib/orgAccess';

const BTN = 'text-[11px] font-black uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const ROLE_LABEL: Record<string, string> = { owner: 'Owner', manager: 'Manager', finance: 'Finance', content: 'Content', scanner: 'Door' };

export default function RoleApiScopesPanel({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [view, setView] = useState<RoleScopesView | null>(null);
  const [draft, setDraft] = useState<Record<string, string[]>>({});
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    getRoleScopes(orgId).then((v) => { setView(v); setDraft({}); }).catch(() => setView(null));
  }, [orgId]);
  useEffect(load, [load]);

  if (!view) return null;
  const editable = view.editable;
  const run = async (fn: () => Promise<RoleScopesView>, ok: string) => {
    setBusy(true);
    try {
      const v = await fn();
      setView({ ...v, editable });
      setDraft({});
      toast({ kind: 'success', message: ok });
    } catch (e) {
      toast({ kind: 'error', message: String((e as Error)?.message ?? e).replace(/^[a-z_]+: /, '') });
    } finally {
      setBusy(false);
    }
  };

  return (
    <fieldset className="bg-[#111] rounded-2xl border border-white/10 p-5 space-y-4">
      <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">API permissions</legend>
      <div className="flex items-start gap-2 text-white/40 text-xs">
        <KeyRound className="w-4 h-4 text-brand-primary shrink-0" aria-hidden="true" />
        <p>
          What API keys and personal or app tokens made by each role may do. Greyed-out boxes are beyond what that role can do
          in the dashboard and can't be given. A change applies to the role's existing keys and tokens on their next request.
          With nothing saved, tokens get the default shown and keys keep their creator's dashboard reach.
          {!editable && ' Only the owner can change this.'}
        </p>
      </div>
      <div className="overflow-x-auto">
        <table className="text-[11px] text-white/80 border-collapse" aria-label="API permissions by role">
          <thead>
            <tr>
              <th scope="col" className="text-left p-1 font-black uppercase tracking-widest text-white/50">Scope</th>
              {view.roles.map((r) => <th key={r.role} scope="col" className="p-1 font-black uppercase tracking-widest text-white/50">{ROLE_LABEL[r.role] ?? r.role}</th>)}
            </tr>
          </thead>
          <tbody>
            {view.scopes.map((s) => (
              <tr key={s} className="border-t border-white/5">
                <th scope="row" className="text-left p-1 font-normal" title={SCOPE_INFO[s as Scope]?.description}>
                  <code>{s}</code>
                </th>
                {view.roles.map((r) => {
                  const inCeiling = r.ceiling.includes(s);
                  const current = draft[r.role] ?? shownScopes(r);
                  const on = r.role === 'owner' ? true : current.includes(s);
                  const disabled = !editable || busy || !r.configurable || !inCeiling;
                  return (
                    <td key={r.role} className={`text-center p-1 ${inCeiling ? '' : 'opacity-30'}`}>
                      <input type="checkbox" checked={on && inCeiling} disabled={disabled}
                        aria-label={`${ROLE_LABEL[r.role] ?? r.role}: ${s}${inCeiling ? '' : ' (not allowed for this role)'}`}
                        onChange={(e) => setDraft({ ...draft, [r.role]: toggleScope(current, s as Scope, e.target.checked) })} />
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
          {editable && (
            <tfoot>
              <tr className="border-t border-white/10">
                <td className="p-1 text-white/40">{view.roles.some((r) => r.configured) ? 'Saved settings apply to keys and tokens' : 'Defaults'}</td>
                {view.roles.map((r) => (
                  <td key={r.role} className="p-1 text-center align-top">
                    {r.configurable && (
                      <Fragment>
                        <button type="button" className={BTN} disabled={busy || !draft[r.role]}
                          onClick={() => run(() => setRoleScopes(orgId, r.role, draft[r.role]), `${ROLE_LABEL[r.role]} API permissions saved.`)}>Save</button>
                        {r.configured && (
                          <button type="button" className={`${BTN} mt-1`} disabled={busy}
                            onClick={() => run(() => resetRoleScopes(orgId, r.role), `${ROLE_LABEL[r.role]} back to the default.`)}>Default</button>
                        )}
                      </Fragment>
                    )}
                  </td>
                ))}
              </tr>
            </tfoot>
          )}
        </table>
      </div>
    </fieldset>
  );
}
