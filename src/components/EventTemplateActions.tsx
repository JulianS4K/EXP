// On an event's edit page (owners and managers): save the event's setup as a
// template, and delete it outright while it is an unsold draft (mig
// 20261102130000). Anything that sold is cancelled instead (the cancel
// section above); the server refuses a delete with orders or tickets.

import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useToast } from '../context/ToastContext';
import { deleteDraftEvent, saveEventAsTemplate } from '../lib/templatesApi';

export default function EventTemplateActions({ eventId, status, ticketsSold }: {
  eventId: string; status: string; ticketsSold: number;
}) {
  const { toast } = useToast();
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  const canDelete = status !== 'published' && ticketsSold === 0;

  const save = async () => {
    const name = window.prompt('Template name:');
    if (name === null) return;
    setBusy(true);
    try {
      await saveEventAsTemplate(eventId, name.trim() || undefined);
      toast({ kind: 'success', title: 'Saved as template', message: 'Find it under Templates.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  const remove = async () => {
    if (!window.confirm('Delete this draft event for good? This can\'t be undone.')) return;
    setBusy(true);
    try {
      await deleteDraftEvent(eventId);
      toast({ kind: 'success', message: 'Draft deleted.' });
      navigate('/dashboard');
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="mt-8 bg-[#111] p-8 border border-white/10">
      <h3 className="text-sm font-black uppercase tracking-tighter italic text-white mb-1">Template and clean-up</h3>
      <p className="text-xs text-white/50 mb-4">
        Save this event's ticket types, prices, fees, capacity, door times and settings as a template for the next one.
        {canDelete ? ' This draft has sold nothing, so it can be deleted outright.' : ' Published or sold events are cancelled, not deleted.'}
      </p>
      <div className="flex flex-wrap gap-2">
        <button type="button" disabled={busy} onClick={save}
          className="px-6 py-3 bg-white/10 hover:bg-white/20 text-white font-black uppercase tracking-tighter italic text-xs transition-all disabled:opacity-40">
          Save as template
        </button>
        {canDelete && (
          <button type="button" disabled={busy} onClick={remove}
            className="px-6 py-3 bg-brand-accent/10 hover:bg-brand-accent/20 text-brand-accent font-black uppercase tracking-tighter italic text-xs transition-all disabled:opacity-40">
            Delete draft
          </button>
        )}
      </div>
    </section>
  );
}
