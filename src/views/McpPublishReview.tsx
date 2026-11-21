// /orgs/:orgId/events/:eventId/publish-review?request=… — where a person
// publishes an event an AI assistant asked to publish (mig 20261119130000,
// docs/mcp.md "Writes"). The assistant can't publish by itself: it hands over
// this link. Signed in as the user the assistant acts for (owner / manager of
// the org), the person sees the event as it is now and clicks Publish, which
// goes through only while the event is unchanged since the assistant's summary.

import { useEffect, useState, type ReactNode } from 'react';
import { Link, useLocation, useParams } from 'react-router-dom';
import { TriangleAlert } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { sqlMessage } from '../lib/developerPlatform';
import {
  approveMessage, approvePublish, fetchPublishReview, publishBlockedReason, requestIdFrom, viaLabel, type PublishReview,
} from '../lib/mcpPublishReview';

const BTN = 'px-5 py-2 text-xs font-black uppercase tracking-widest border disabled:opacity-40';

export default function McpPublishReview() {
  const { user, openAuthModal } = useAuth();
  const { eventId } = useParams();
  const location = useLocation();
  const requestId = requestIdFrom(location.search);
  const [view, setView] = useState<PublishReview | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);

  useEffect(() => {
    if (!user || !requestId) return;
    fetchPublishReview(requestId).then(setView).catch((e) => setFailure(sqlMessage(e)));
  }, [user, requestId]);

  if (!requestId) return <Shell><Problem text="This link is missing its request. Ask the assistant for a new one." /></Shell>;
  if (!user) {
    return (
      <Shell>
        <p className="text-sm text-white/70">Sign in to Exos to review and publish this event.</p>
        <button type="button" className={`${BTN} border-brand-primary text-brand-primary`} onClick={openAuthModal}>Sign in</button>
      </Shell>
    );
  }
  if (failure) return <Shell><Problem text={failure} /></Shell>;
  if (!view) return <Shell><p className="text-sm text-white/50">Loading…</p></Shell>;
  const st = view.state;
  if (!st || st.event.id !== eventId) return <Shell><Problem text="This publish request doesn't match this event." /></Shell>;
  const blocked = publishBlockedReason(view);

  return (
    <Shell>
      <h1 className="text-lg font-black">Publish {st.event.name}?</h1>
      <p className="text-[11px] text-white/50">Asked by {viaLabel(view.request)}. Only you can publish it, here.</p>
      <dl className="text-xs space-y-1">
        <div><dt className="inline text-white/50">Starts: </dt><dd className="inline">{st.event.starts_at ?? 'not set'} {st.event.timezone ? `(${st.event.timezone})` : ''}</dd></div>
        <div><dt className="inline text-white/50">Venue: </dt><dd className="inline">{st.event.venue_name ?? 'not set'}</dd></div>
      </dl>
      <div>
        <p className="text-[10px] uppercase tracking-widest text-white/50">Ticket types</p>
        <ul className="text-xs space-y-1">
          {st.ticket_types.map((t) => (
            <li key={t.id}>{t.name}: {Number(t.price) === 0 ? 'free' : `${Number(t.price).toFixed(2)} ${st.event.currency}`}, {t.capacity} tickets</li>
          ))}
        </ul>
      </div>
      {view.fee && (
        <p className="text-xs text-white/70">
          {view.fee.free_tier ? `Free tier: no Exos fee (under ${view.fee.free_tier_max_capacity + 1} tickets).` : 'The standard Exos fee applies.'}
        </p>
      )}
      <p className="text-[11px] text-white/50">Once published, people can find the event and buy tickets.</p>
      {done ? (
        <p className="text-sm" role="status">{done}</p>
      ) : blocked ? (
        <Problem text={blocked} />
      ) : (
        <button type="button" className={`${BTN} border-brand-primary bg-brand-primary text-black`} disabled={busy}
          onClick={async () => {
            setBusy(true);
            try {
              setDone(approveMessage(await approvePublish(requestId)));
            } catch (e) {
              setFailure(sqlMessage(e));
            } finally {
              setBusy(false);
            }
          }}>
          Publish
        </button>
      )}
      <p className="text-[11px] text-white/40"><Link className="underline" to={`/edit-event/${st.event.id}`}>Open the event in the editor</Link></p>
    </Shell>
  );
}

function Shell({ children }: { children: ReactNode }) {
  return <div className="max-w-md mx-auto px-4 py-16 text-white"><div className="bg-[#111] border border-white/10 p-6 space-y-4">{children}</div></div>;
}

function Problem({ text }: { text: string }) {
  return <p className="text-sm text-white flex items-start gap-2"><TriangleAlert className="w-4 h-4 text-amber-400 shrink-0" aria-hidden="true" /> {text}</p>;
}
