// Org settings → Discord (mig 20261113130000; docs/discord.md): promote events
// in the org's own Discord server. A channel webhook for announcements, the
// platform's bot for Discord scheduled events, and the switches. Hidden
// unless the operator turned Discord on (exos-discord /config). The webhook
// URL is a secret: it's pasted once and never shown again (a hint only).

import { useCallback, useEffect, useState } from 'react';
import { MessageSquare } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  fetchDiscordConfig, fetchDiscordStatus, removeDiscordWebhook, saveDiscordWebhook, setDiscordOptions, startDiscordInstall,
  orgPausedLine, unlinkDiscordServer, webhookUrlOk, type DiscordConfig, type DiscordStatus,
} from '../lib/discord';

const LBL = 'block text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1';
const FLD = 'w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
const BTN = 'px-3 py-1.5 rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
const SUB = 'text-[10px] font-black text-slate-600 uppercase tracking-widest';

export default function DiscordPanel({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [cfg, setCfg] = useState<DiscordConfig | null>(null);
  const [st, setSt] = useState<DiscordStatus | null>(null);
  const [url, setUrl] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    fetchDiscordStatus(orgId).then(setSt).catch(() => setSt(null));
  }, [orgId]);
  useEffect(() => {
    fetchDiscordConfig().then((c) => { setCfg(c); if (c.enabled) load(); });
  }, [load]);
  if (!cfg?.enabled || !st) return null;
  const manage = st.canManage;

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast({ kind: 'success', message: ok });
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  const urlBad = url.trim() !== '' && !webhookUrlOk(url);

  return (
    <section data-testid="discord-panel" aria-labelledby="discord-title" className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-5">
      <div className="flex items-center gap-2">
        <MessageSquare className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h2 id="discord-title" className="text-sm font-black text-slate-900 uppercase tracking-widest">Discord</h2>
      </div>
      <p className="text-xs text-slate-600">
        Promote your events in your own Discord server: an announcement in a channel when an event goes on sale, and the
        event on the server&apos;s Events list. Exos never pings anyone, and changes nothing else on your server.
      </p>
      {st.paused && (
        <p role="status" className="text-[11px] text-rose-800 bg-rose-50 border border-rose-200 rounded px-3 py-2">
          Discord is paused on this Exos server (Discord refused too many requests). Nothing is sent until an operator clears it.
        </p>
      )}
      {orgPausedLine(st.orgPausedUntil) && (
        <p role="status" className="text-[11px] text-rose-800 bg-rose-50 border border-rose-200 rounded px-3 py-2">
          {orgPausedLine(st.orgPausedUntil)}
        </p>
      )}
      {(!cfg.writes || !st.writesEnabled) && (
        <p className="text-[11px] text-amber-800 bg-amber-50 border border-amber-200 rounded px-3 py-2">
          Dry run: Exos records what it would post but sends nothing to Discord
          {!cfg.writes ? ' (Discord writes are off on this Exos server).' : ' until an owner turns sending on below.'}
        </p>
      )}

      <div className="space-y-2">
        <h3 className={SUB}>Announcements (channel webhook)</h3>
        <p className="text-[11px] text-slate-600">
          In Discord: the channel&apos;s settings, Integrations, Webhooks, New Webhook, Copy Webhook URL. Paste it here.
          {st.webhook.set ? ` Saved: webhook ${st.webhook.hint ?? ''}.` : ' No webhook yet.'}
        </p>
        {st.webhook.broken && (
          <p className="text-[11px] text-rose-700">Discord refused this webhook (deleted, or the URL is wrong). Paste a new one.</p>
        )}
        {manage && (
          <>
            <label className="block">
              <span className={LBL}>{st.webhook.set ? 'Replace the webhook URL' : 'Channel webhook URL'}</span>
              <input className={FLD} type="password" value={url} autoComplete="off" spellCheck={false}
                placeholder="https://discord.com/api/webhooks/…" aria-invalid={urlBad} aria-describedby={urlBad ? 'discord-url-err' : undefined}
                onChange={(e) => setUrl(e.target.value)} />
            </label>
            {urlBad && <p id="discord-url-err" className="text-[11px] text-rose-700">That isn&apos;t a Discord channel webhook URL.</p>}
            <div className="flex flex-wrap gap-2">
              <button type="button" className={`${BTN} bg-tm-blue text-white`} disabled={busy || !url.trim() || urlBad}
                onClick={() => void run(async () => { await saveDiscordWebhook(orgId, url); setUrl(''); }, 'Discord webhook saved.')}>
                Save webhook
              </button>
              {st.webhook.set && (
                <button type="button" className={`${BTN} border border-rose-200 text-rose-700`} disabled={busy}
                  onClick={() => void run(() => removeDiscordWebhook(orgId), 'Discord webhook removed.')}>
                  Remove webhook
                </button>
              )}
            </div>
            <label className="flex items-start gap-2 text-xs text-slate-700">
              <input type="checkbox" className="mt-0.5" checked={st.autoPost} disabled={busy || !st.webhook.set}
                onChange={(e) => void run(() => setDiscordOptions(orgId, { autoPost: e.target.checked }),
                  e.target.checked ? 'New events will be announced on Discord.' : 'Automatic announcements off.')} />
              <span>Announce each event on Discord when it&apos;s published (once per event).</span>
            </label>
          </>
        )}
      </div>

      {cfg.bot && (
        <div className="space-y-2">
          <h3 className={SUB}>Discord events (the Exos bot)</h3>
          <p className="text-[11px] text-slate-600">
            {st.guild.linked && st.guild.broken
              ? `The Exos bot lost access to ${st.guild.name ?? 'your server'} (removed, or its permission was taken away). Reconnect the bot.`
              : st.guild.linked
              ? `Linked to ${st.guild.name ?? 'your server'}. Tick "Show on Discord" on an event to list it on the server's Events tab; ${st.shownEvents} shown now.`
              : 'Add the Exos bot to your server (you need Manage Server there). It can only create and update the events it lists.'}
          </p>
          {manage && (
            <div className="flex flex-wrap gap-2">
              {(!st.guild.linked || st.guild.broken) && (
                <button type="button" className={`${BTN} bg-tm-blue text-white`} disabled={busy}
                  onClick={() => void (async () => {
                    setBusy(true);
                    try { window.location.assign(await startDiscordInstall(orgId)); } catch (e) {
                      toast({ kind: 'error', message: (e as Error).message });
                      setBusy(false);
                    }
                  })()}>
                  {st.guild.broken ? 'Reconnect the bot' : 'Add Exos bot to your server'}
                </button>
              )}
              {st.guild.linked && (
                <button type="button" className={`${BTN} border border-rose-200 text-rose-700`} disabled={busy}
                  onClick={() => void run(() => unlinkDiscordServer(orgId),
                    'Server disconnected. Remove the Exos bot in Discord (Server settings, Integrations) to finish.')}>
                  Disconnect server
                </button>
              )}
            </div>
          )}
        </div>
      )}

      {manage && (
        <label className="flex items-start gap-2 text-xs text-slate-700">
          <input type="checkbox" className="mt-0.5" checked={st.writesEnabled} disabled={busy || !st.isOwner}
            onChange={(e) => void run(() => setDiscordOptions(orgId, { writes: e.target.checked }),
              e.target.checked ? 'Exos will send to Discord.' : 'Discord sending off: dry run only.')} />
          <span>
            Send to Discord (otherwise a dry run).{!st.isOwner && ' Only an owner can change this.'}
          </span>
        </label>
      )}
    </section>
  );
}
