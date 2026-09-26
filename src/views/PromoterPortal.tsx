// /p/:token — a promoter's private portal (mig 20260924233000). No login: the
// token in the link is the secret. Shows their own tickets + gross per event
// and, for any event, their kit (buy-now link, story poster, tracked links).
// Earnings (commission owed / paid, mig 20260926020000): PromoterEarningsPanel.

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Megaphone } from 'lucide-react';
import type { Event } from '../types';
import { getPromoterKit, linkInBioPath, type PromoterKitData } from '../lib/promoters';
import { publicUrl } from '../lib/utils';
import { useToast } from '../context/ToastContext';
import { getPublicEvent } from '../lib/events';
import { applyMeta } from '../lib/meta';
import { formatCurrency } from '../lib/utils';
import PromoterKitPanel from '../components/PromoterKitPanel';
import PromoterSocialsForm from '../components/PromoterSocialsForm';
import PromoterGuestListForm from '../components/PromoterGuestListForm';
import PromoterEarningsPanel from '../components/PromoterEarningsPanel';

export default function PromoterPortal() {
  const { token } = useParams();
  const [kit, setKit] = useState<PromoterKitData | null>(null);
  const [loading, setLoading] = useState(true);
  const [openEvent, setOpenEvent] = useState<Event | null>(null);
  const { toast } = useToast();

  useEffect(() => {
    try { applyMeta({ title: 'Promoter portal', description: 'Your events and sales.', noindex: true }); } catch { /* non-fatal */ }
    if (!token || !/^[0-9a-f-]{36}$/i.test(token)) { setLoading(false); return; }
    getPromoterKit(token).then(setKit).finally(() => setLoading(false));
  }, [token]);

  const open = async (eventId: string) => {
    if (openEvent?.id === eventId) { setOpenEvent(null); return; }
    setOpenEvent(await getPublicEvent(eventId));
  };

  if (loading) return <div className="max-w-3xl mx-auto p-20 text-center type text-white/40 uppercase tracking-widest text-xs">Loading…</div>;
  if (!kit) {
    return (
      <div className="max-w-3xl mx-auto p-20 text-center">
        <p className="type text-white/40 uppercase tracking-widest text-[10px] mb-4">This promoter link isn't active. Ask the organizer for a new one.</p>
        <Link to="/" className="text-brand-primary font-bold text-sm">Browse events</Link>
      </div>
    );
  }

  const total = kit.events.reduce((n, e) => n + (e.tickets || 0), 0);
  return (
    <div className="max-w-3xl mx-auto px-4 py-12">
      <p className="type text-[10px] text-white/40 uppercase tracking-widest mb-2">Promoter · {kit.promoter.code} · {kit.org.name}</p>
      <div className="flex items-center gap-3 mb-2">
        <Megaphone className="w-6 h-6 text-brand-primary" />
        <h1 className="disp text-4xl uppercase tracking-wide text-white">{kit.promoter.name}</h1>
      </div>
      <p className="text-sm text-white/60 mb-6">{total} ticket{total === 1 ? '' : 's'} sold through your links. Keep this page private: it's your link.</p>
      <div className="bg-[#111] border border-brand-primary/40 p-4 mb-8">
        <p className="type text-[10px] uppercase tracking-widest text-brand-primary mb-2">Your link in bio</p>
        <p className="text-xs text-white/60 mb-3">Put this one link in your Instagram or TikTok bio. It always lists {kit.org.name}'s upcoming events, and every sale through it is yours.</p>
        <button
          onClick={async () => {
            try { await navigator.clipboard.writeText(publicUrl(linkInBioPath(kit.org.slug, kit.promoter.code))); toast({ kind: 'success', message: 'Link in bio copied.' }); }
            catch { toast({ kind: 'error', message: 'Could not copy. Long-press the link to copy it.' }); }
          }}
          className="w-full text-left text-[11px] font-mono text-white/80 truncate bg-black border border-white/10 px-3 py-2"
        >
          {publicUrl(linkInBioPath(kit.org.slug, kit.promoter.code))}
        </button>
      </div>
      {token && <PromoterEarningsPanel token={token} />}
      {token && (
        <PromoterSocialsForm
          token={token}
          socials={kit.promoter.socials ?? {}}
          allowTagging={kit.promoter.allow_tagging !== false}
        />
      )}
      {token && <PromoterGuestListForm token={token} />}
      <div className="space-y-3">
        {kit.events.length === 0 && <p className="text-[11px] text-white/40 italic">No events on sale right now.</p>}
        {kit.events.map((e) => (
          <section key={e.event_id} className="bg-[#111] border border-white/10">
            <button onClick={() => open(e.event_id)} className="w-full flex items-center justify-between gap-4 px-5 py-4 text-left">
              <span className="font-black text-white truncate">{e.name}</span>
              <span className="type text-[10px] uppercase tracking-widest text-white/60 shrink-0">
                {e.tickets} sold · {formatCurrency(Number(e.gross) || 0, e.currency || 'USD')} incl. add-ons &amp; tax
              </span>
            </button>
            {openEvent?.id === e.event_id && (
              <div className="border-t border-white/10 p-5">
                <PromoterKitPanel event={openEvent} promoter={kit.promoter.code} />
              </div>
            )}
          </section>
        ))}
      </div>
    </div>
  );
}
