// Edit event → Promote on Discord (mig 20261113130000; docs/discord.md): show
// the event on the org's Discord server (a Discord scheduled event Exos keeps
// in step), and post its announcement or a reminder through the org's
// channel webhook, once each. Hidden unless the operator turned Discord on
// and the org connected something (Org settings → Discord).

import { useCallback, useEffect, useState } from 'react';
import { MessageSquare } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  autoReminderLine, fetchDiscordConfig, fetchDiscordEventStatus, orgPausedLine, postLine, postToDiscord, setDiscordShow, syncLine,
  type DiscordEventStatus, type PostKind,
} from '../lib/discord';

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';

export default function DiscordEventPanel({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [st, setSt] = useState<DiscordEventStatus | null>(null);
  const [bot, setBot] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    fetchDiscordEventStatus(eventId).then(setSt).catch(() => setSt(null));
  }, [eventId]);
  useEffect(() => {
    fetchDiscordConfig().then((c) => { if (c.enabled) { setBot(c.bot); load(); } });
  }, [load]);
  if (!st || !st.canManage || (!st.hasWebhook && !st.guildLinked)) return null;

  const run = async (fn: () => Promise<string>) => {
    setBusy(true);
    try {
      toast({ kind: 'success', message: await fn() });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
      load();
    }
  };
  const post = (kind: PostKind) => run(async () => {
    const r = await postToDiscord(eventId, kind);
    if (r.already) return kind === 'publish' ? 'Already posted to Discord.' : 'The reminder was already posted.';
    return r.status === 'dry_run' ? 'Dry run: recorded, not sent (Discord writes are off).' : r.status === 'sent' ? 'Posted to Discord.' : 'Posting to Discord…';
  });
  const postOf = (k: PostKind) => st.posts.find((p) => p.kind === k);
  const published = st.eventStatus === 'published';

  return (
    <section data-testid="discord-event-panel" aria-labelledby="discord-event-title" className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-5">
      <div className="flex items-center space-x-3">
        <MessageSquare className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 id="discord-event-title" className="disp text-lg uppercase tracking-wide text-white leading-none">Promote on Discord</h2>
      </div>

      {orgPausedLine(st.orgPausedUntil) && (
        <p role="status" className="type text-[11px] text-rose-300">{orgPausedLine(st.orgPausedUntil)}</p>
      )}

      {bot && st.guildLinked && (
        <div className="space-y-2">
          <label className="flex items-start gap-2 type text-xs text-white/80">
            <input type="checkbox" className="mt-0.5" checked={st.show} disabled={busy || (!st.show && st.eventStatus === 'cancelled')}
              onChange={(e) => void run(async () => {
                await setDiscordShow(eventId, e.target.checked);
                return e.target.checked ? 'Showing on Discord.' : 'Taking it off Discord.';
              })} />
            <span>Show on Discord ({st.guildName ?? 'your server'}&apos;s Events tab). Edits here go there; cancelling or deleting the event here takes it off there.</span>
          </label>
          <p className="type text-[11px] text-white/60" aria-live="polite">{syncLine(st)}</p>
        </div>
      )}

      {st.hasWebhook && (
        <div className="space-y-3">
          {st.webhookBroken && (
            <p className="type text-[11px] text-rose-300">Discord refused the org&apos;s webhook. Paste a new one in Org settings → Discord.</p>
          )}
          {(['publish', 'reminder'] as PostKind[]).map((k) => {
            const p = postOf(k);
            const done = p?.status === 'sent' || p?.status === 'queued' || p?.status === 'sending';
            return (
              <div key={k} className="flex flex-wrap items-center gap-3">
                <button type="button" className={BTN} disabled={busy || done || !published} onClick={() => void post(k)}>
                  {k === 'publish' ? 'Post to Discord' : 'Post a reminder'}
                </button>
                <span className="type text-[11px] text-white/60">{published ? postLine(p) : 'Publish the event to post it.'}</span>
              </div>
            );
          })}
          {autoReminderLine(st) && <p className="type text-[11px] text-white/60">{autoReminderLine(st)}</p>}
          <p className="type text-[11px] text-white/50">One announcement and one reminder per event, never with @everyone or other mentions.</p>
        </div>
      )}
    </section>
  );
}
