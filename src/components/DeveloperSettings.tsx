// Org developer settings — API keys + outbound webhooks (Hi.Events parity).
//
// Self-contained CRUD embedded in OrgSettings (dark theme). API keys: create
// with a chosen set of scopes (_shared/api/scopes.ts; defaults to every
// `:read` scope) shows the plaintext ONCE (irrecoverable); the list shows the
// prefix and each key's scopes, which an owner/manager can change on a live
// key; revoke. At most 10 active keys per org (mig 20261027090000). The API
// reference is the public /developers page.
// Webhooks: register an HTTPS endpoint + subscribe to event types; the signing
// secret is shown so the receiver can verify the X-Exos-Signature header.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Key, Webhook as WebhookIcon, Trash2, Plus, Copy, EyeOff, BookOpen } from 'lucide-react';
import {
  createApiKey, revokeApiKey, listApiKeys, setApiKeyScopes, type ApiKey,
  ApiKeyLimitError, DEFAULT_KEY_SCOPES, MAX_ACTIVE_API_KEYS, isLegacyReadKey,
  listWebhooks, createWebhook, setWebhookEnabled, deleteWebhook,
  WEBHOOK_EVENT_TYPES, type Webhook,
} from '../lib/orgApi';
import { LEGACY_READ, READ_SCOPES, SCOPES, SCOPE_INFO, isScope, type Scope } from '../../supabase/functions/_shared/api/scopes.ts';
import { useToast } from '../context/ToastContext';

/** The picker's starting set for a live key: its scopes, with the legacy `read` spelled out. */
function pickerScopes(scopes: readonly string[]): Scope[] {
  const out = new Set<Scope>(scopes.filter(isScope));
  if (scopes.includes(LEGACY_READ)) for (const s of READ_SCOPES) out.add(s);
  return SCOPES.filter((s) => out.has(s));
}

function ScopeChips({ scopes }: { scopes: readonly string[] }) {
  return (
    <div className="flex flex-wrap gap-1 mt-1">
      {isLegacyReadKey(scopes) && (
        <span className="text-[10px] font-bold px-1.5 py-0.5 border border-white/15 text-white/70" title="Legacy read scope: every :read scope">
          All read access
        </span>
      )}
      {scopes.filter((s) => s !== LEGACY_READ).map((s) => (
        <span key={s} className="text-[10px] font-mono px-1.5 py-0.5 border border-white/15 text-white/60" title={isScope(s) ? SCOPE_INFO[s].description : undefined}>
          {s}
        </span>
      ))}
    </div>
  );
}

/** One checkbox per scope, with what it allows. */
function ScopePicker({ value, onChange, idPrefix }: { value: readonly Scope[]; onChange: (next: Scope[]) => void; idPrefix: string }) {
  const toggle = (s: Scope) =>
    onChange(SCOPES.filter((x) => (x === s ? !value.includes(s) : value.includes(x))));
  return (
    <fieldset className="space-y-2">
      <legend className="text-[10px] text-white/50 font-black uppercase tracking-widest mb-1">Scopes</legend>
      <div className="grid sm:grid-cols-2 gap-x-4 gap-y-1.5">
        {SCOPES.map((s) => (
          <label key={s} htmlFor={`${idPrefix}-${s}`} className="flex items-start gap-2 cursor-pointer">
            <input
              id={`${idPrefix}-${s}`}
              type="checkbox"
              checked={value.includes(s)}
              onChange={() => toggle(s)}
              className="mt-0.5 accent-brand-primary"
            />
            <span className="min-w-0">
              <span className="block text-xs text-white">
                {SCOPE_INFO[s].label} <code className="text-[10px] text-white/40">{s}</code>
              </span>
              <span className="block text-[11px] text-white/40 leading-snug">{SCOPE_INFO[s].description}</span>
            </span>
          </label>
        ))}
      </div>
      <p className="text-[11px] text-white/40">
        Writes exist for booking only (venues, holds, show schedules); the finance and commerce scopes are for routes to come.
      </p>
    </fieldset>
  );
}

export default function DeveloperSettings({ orgId, canEdit }: { orgId: string; canEdit: boolean }) {
  const { toast } = useToast();
  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [hooks, setHooks] = useState<Webhook[]>([]);
  const [newKeyName, setNewKeyName] = useState('');
  const [newScopes, setNewScopes] = useState<Scope[]>([...DEFAULT_KEY_SCOPES]);
  const [keyError, setKeyError] = useState<string | null>(null);
  const [freshKey, setFreshKey] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // The live key whose scopes are being edited, and the draft.
  const [editing, setEditing] = useState<{ id: string; scopes: Scope[] } | null>(null);

  const [hookUrl, setHookUrl] = useState('');
  const [hookTypes, setHookTypes] = useState<string[]>([...WEBHOOK_EVENT_TYPES]);

  const reload = async () => {
    try {
      const [k, w] = await Promise.all([listApiKeys(orgId), listWebhooks(orgId)]);
      setKeys(k);
      setHooks(w);
    } catch (e) {
      console.error('developer settings load failed:', e);
    }
  };
  useEffect(() => { reload(); /* eslint-disable-next-line */ }, [orgId]);

  const activeKeys = keys.filter((k) => !k.revokedAt).length;
  const atCap = activeKeys >= MAX_ACTIVE_API_KEYS;

  const genKey = async () => {
    if (newScopes.length === 0) {
      setKeyError('Pick at least one scope.');
      return;
    }
    setBusy(true);
    setKeyError(null);
    try {
      const key = await createApiKey(orgId, newKeyName.trim() || undefined, newScopes);
      setFreshKey(key);
      setNewKeyName('');
      setNewScopes([...DEFAULT_KEY_SCOPES]);
      await reload();
    } catch (e: any) {
      const message = e?.message || 'Could not create key.';
      // The cap stays on screen next to the form, not just in a toast.
      if (e instanceof ApiKeyLimitError) setKeyError(message);
      toast({ kind: 'error', message });
    } finally {
      setBusy(false);
    }
  };

  const saveScopes = async () => {
    if (!editing) return;
    if (editing.scopes.length === 0) {
      toast({ kind: 'error', message: 'A key needs at least one scope.' });
      return;
    }
    setBusy(true);
    try {
      await setApiKeyScopes(editing.id, editing.scopes);
      setEditing(null);
      await reload();
      toast({ kind: 'success', message: 'Scopes updated.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not update scopes.' });
    } finally {
      setBusy(false);
    }
  };

  const revoke = async (id: string) => {
    try { await revokeApiKey(id); await reload(); }
    catch (e: any) { toast({ kind: 'error', message: e?.message || 'Could not revoke.' }); }
  };

  const addHook = async () => {
    if (!/^https:\/\//.test(hookUrl.trim())) {
      toast({ kind: 'error', message: 'Webhook URL must start with https://' });
      return;
    }
    setBusy(true);
    try {
      await createWebhook(orgId, hookUrl.trim(), hookTypes);
      setHookUrl('');
      setHookTypes([...WEBHOOK_EVENT_TYPES]);
      await reload();
      toast({ kind: 'success', message: 'Webhook added.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not add webhook.' });
    } finally {
      setBusy(false);
    }
  };

  const copy = (text: string) => {
    navigator.clipboard.writeText(text)
      .then(() => toast({ kind: 'success', message: 'Copied.' }))
      .catch(() => toast({ kind: 'error', message: 'Copy failed.' }));
  };

  const toggleType = (t: string) =>
    setHookTypes((cur) => (cur.includes(t) ? cur.filter((x) => x !== t) : [...cur, t]));

  return (
    // Its own dark panel: the settings page around it is light.
    <fieldset className="bg-[#111] rounded-2xl border border-white/10 p-5 space-y-6">
      <legend className="text-[10px] text-white/60 font-black uppercase tracking-widest px-2">
        Developer — API &amp; webhooks
      </legend>

      {/* API keys */}
      <div className="space-y-3">
        <div className="flex items-center gap-2 text-white/70">
          <Key className="w-4 h-4 text-brand-primary" />
          <span className="text-[11px] font-black uppercase tracking-widest">API keys</span>
        </div>
        <p className="text-white/40 text-xs">
          Authenticate the REST API with <code className="text-brand-primary">Authorization: Bearer &lt;key&gt;</code>.
          Shown once at creation — store it safely. Give each key only the scopes its integration needs.{' '}
          <Link to="/developers" className="inline-flex items-center gap-1 text-brand-primary hover:underline">
            <BookOpen className="w-3 h-3" aria-hidden="true" /> API reference
          </Link>
        </p>

        {freshKey && (
          <div className="bg-brand-primary/10 border border-brand-primary/40 p-3 space-y-2">
            <p className="text-[10px] text-brand-primary font-black uppercase tracking-widest">
              Copy now — you won't see this again
            </p>
            <div className="flex items-center gap-2">
              <code className="flex-1 text-xs text-white font-mono break-all">{freshKey}</code>
              <button type="button" onClick={() => copy(freshKey)} className="text-white/60 hover:text-white" aria-label="Copy key">
                <Copy className="w-4 h-4" />
              </button>
              <button type="button" onClick={() => setFreshKey(null)} className="text-white/60 hover:text-white" aria-label="Dismiss">
                <EyeOff className="w-4 h-4" />
              </button>
            </div>
          </div>
        )}

        {keys.map((k) => (
          <div key={k.id} className="bg-white/5 border border-white/10 px-3 py-2 space-y-2">
            <div className="flex items-start justify-between">
              <div className="min-w-0 pr-3">
                <p className="text-sm text-white font-bold truncate">
                  {k.name || 'Untitled key'} {k.revokedAt && <span className="text-red-400 text-xs">(revoked)</span>}
                </p>
                <p className="text-white/40 text-xs font-mono">
                  {k.keyPrefix}…{k.lastUsedAt ? ` · used ${new Date(k.lastUsedAt).toLocaleDateString()}` : ' · never used'}
                </p>
                <ScopeChips scopes={k.scopes} />
              </div>
              {canEdit && !k.revokedAt && (
                <div className="flex items-center gap-3 shrink-0">
                  <button
                    type="button"
                    onClick={() => setEditing(editing?.id === k.id ? null : { id: k.id, scopes: pickerScopes(k.scopes) })}
                    aria-expanded={editing?.id === k.id}
                    className="text-white/40 hover:text-white text-[10px] font-black uppercase tracking-widest"
                  >
                    Scopes
                  </button>
                  <button type="button" onClick={() => revoke(k.id)} className="text-white/40 hover:text-red-400 text-[10px] font-black uppercase tracking-widest">
                    Revoke
                  </button>
                </div>
              )}
            </div>
            {editing?.id === k.id && (
              <div className="border-t border-white/10 pt-2 space-y-2">
                {isLegacyReadKey(k.scopes) && (
                  <p className="text-[11px] text-amber-300/80">
                    This key has the legacy “all read access” scope. Saving replaces it with exactly the scopes ticked here.
                  </p>
                )}
                <ScopePicker idPrefix={`key-${k.id}`} value={editing.scopes} onChange={(scopes) => setEditing({ id: k.id, scopes })} />
                <div className="flex gap-2">
                  <button type="button" disabled={busy || editing.scopes.length === 0} onClick={saveScopes} className="px-3 py-2 bg-white/10 hover:bg-white/20 text-[10px] font-black uppercase tracking-widest text-white disabled:opacity-50">
                    Save scopes
                  </button>
                  <button type="button" onClick={() => setEditing(null)} className="px-3 py-2 text-[10px] font-black uppercase tracking-widest text-white/50 hover:text-white">
                    Cancel
                  </button>
                </div>
              </div>
            )}
          </div>
        ))}

        {canEdit && (
          <div className="space-y-3 border border-white/10 p-3">
            <p className="text-[10px] text-white/50 font-black uppercase tracking-widest">
              New key · {activeKeys} of {MAX_ACTIVE_API_KEYS} active
            </p>
            {atCap ? (
              <p role="alert" className="text-xs text-red-300">
                Your organization has {MAX_ACTIVE_API_KEYS} active API keys, the most it can have. Revoke one to create another.
              </p>
            ) : (
              <>
                <input
                  value={newKeyName}
                  onChange={(e) => setNewKeyName(e.target.value)}
                  placeholder="Key name (e.g. Zapier)"
                  aria-label="Key name"
                  className="w-full bg-white/5 border border-white/10 px-3 py-2 text-sm text-white focus:border-brand-primary focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60"
                />
                <ScopePicker idPrefix="new-key" value={newScopes} onChange={(v) => { setNewScopes(v); setKeyError(null); }} />
                {keyError && <p role="alert" className="text-xs text-red-300">{keyError}</p>}
                <button type="button" disabled={busy || newScopes.length === 0} onClick={genKey} className="flex items-center gap-1 px-3 py-2 bg-white/10 hover:bg-white/20 text-[10px] font-black uppercase tracking-widest text-white disabled:opacity-50">
                  <Plus className="w-3 h-3" /> New key
                </button>
              </>
            )}
          </div>
        )}
      </div>

      {/* Webhooks */}
      <div className="space-y-3 pt-2 border-t border-white/10">
        <div className="flex items-center gap-2 text-white/70">
          <WebhookIcon className="w-4 h-4 text-brand-primary" />
          <span className="text-[11px] font-black uppercase tracking-widest">Webhooks</span>
        </div>
        <p className="text-white/40 text-xs">
          We POST signed events to your URL. <code className="text-brand-primary">X-Exos-Signature: sha256=…</code> is
          the HMAC-SHA256, with your secret, of <code className="text-brand-primary">{'<X-Exos-Timestamp>.<raw body>'}</code>.
          Reject timestamps more than 5 minutes old, and skip a repeated <code className="text-brand-primary">X-Exos-Delivery</code> id.
        </p>

        {hooks.map((h) => (
          <div key={h.id} className="bg-white/5 border border-white/10 px-3 py-2 space-y-1">
            <div className="flex items-center justify-between gap-2">
              <p className="text-sm text-white font-mono truncate min-w-0">{h.url}</p>
              <div className="flex items-center gap-3 shrink-0">
                {canEdit && (
                  <button
                    type="button"
                    onClick={() => setWebhookEnabled(h.id, !h.enabled).then(reload)}
                    className={`text-[10px] font-black uppercase tracking-widest ${h.enabled ? 'text-green-400' : 'text-white/30'}`}
                  >
                    {h.enabled ? 'Enabled' : 'Disabled'}
                  </button>
                )}
                {canEdit && (
                  <button type="button" onClick={() => deleteWebhook(h.id).then(reload)} className="text-white/40 hover:text-red-400" aria-label="Delete webhook">
                    <Trash2 className="w-4 h-4" />
                  </button>
                )}
              </div>
            </div>
            <p className="text-white/40 text-[11px]">{h.eventTypes.join(', ')}</p>
            <div className="flex items-center gap-2">
              <span className="text-white/30 text-[10px] uppercase tracking-widest">Secret</span>
              <code className="text-white/50 text-[11px] font-mono truncate">{h.secret.slice(0, 10)}…</code>
              <button type="button" onClick={() => copy(h.secret)} className="text-white/40 hover:text-white" aria-label="Copy secret">
                <Copy className="w-3 h-3" />
              </button>
            </div>
          </div>
        ))}

        {canEdit && (
          <div className="space-y-2">
            <input
              value={hookUrl}
              onChange={(e) => setHookUrl(e.target.value)}
              placeholder="https://your-app.com/webhooks/exos"
              className="w-full bg-white/5 border border-white/10 px-3 py-2 text-sm text-white focus:border-brand-primary focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60"
            />
            <div className="flex flex-wrap gap-2">
              {WEBHOOK_EVENT_TYPES.map((t) => (
                <button
                  key={t}
                  type="button"
                  onClick={() => toggleType(t)}
                  className={`text-[10px] font-bold px-2 py-1 border transition-all ${hookTypes.includes(t) ? 'border-brand-primary text-brand-primary' : 'border-white/15 text-white/40'}`}
                >
                  {t}
                </button>
              ))}
            </div>
            <button type="button" disabled={busy} onClick={addHook} className="flex items-center gap-1 px-3 py-2 bg-white/10 hover:bg-white/20 text-[10px] font-black uppercase tracking-widest text-white disabled:opacity-50">
              <Plus className="w-3 h-3" /> Add webhook
            </button>
          </div>
        )}
      </div>
    </fieldset>
  );
}
