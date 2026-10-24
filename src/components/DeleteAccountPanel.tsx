import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { deleteMyAccount, deletionErrorMessage } from '../lib/account';

/** Profile → settings: permanently close the signed-in account. */
export default function DeleteAccountPanel() {
  const { logout } = useAuth();
  const { toast } = useToast();
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);

  const run = async () => {
    setBusy(true);
    try {
      await deleteMyAccount();
      await logout({ skipDoorCheck: true });
      toast({ kind: 'success', message: 'Your account has been deleted.' });
      navigate('/');
    } catch (err) {
      toast({ kind: 'error', message: deletionErrorMessage(err) });
      setBusy(false);
    }
  };

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="type text-[12px] uppercase tracking-widest text-red-400 hover:text-red-300 transition-colors"
      >
        delete my account
      </button>
    );
  }

  return (
    <div className="border border-red-500/40 bg-red-500/10 p-4 space-y-3" role="dialog" aria-label="Delete my account">
      <p className="text-xs text-white/80 leading-relaxed">
        This permanently deletes your Exos account: your profile, follows, saved events, waitlist spots, team
        memberships, queued emails and text-message subscriptions, and the email and name on your past orders,
        tickets and invoices, including guest checkouts made with the same email. You're taken off every organizer's
        marketing and ad lists for good; to keep it that way we keep only a one-way scrambled copy (hash) of your
        email, never the address. Organizers keep an anonymous record of past orders and invoices (amounts, no
        contact details). Guest-list entries an organizer typed in themselves stay with that organizer. You can't
        undo this.
      </p>
      <p className="text-xs text-white/60 leading-relaxed">
        You can't delete while you hold tickets for an upcoming event, have a transfer pending, or own an organization
        (make a teammate the owner on its Members page first).
      </p>
      <label className="block text-[10px] uppercase tracking-widest text-white/50" htmlFor="delete-confirm">
        Type DELETE to confirm
      </label>
      <input
        id="delete-confirm"
        value={confirm}
        onChange={(e) => setConfirm(e.target.value)}
        autoComplete="off"
        className="w-full bg-black border border-white/20 px-3 py-2 text-sm font-bold focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-red-400"
      />
      <div className="flex gap-3">
        <button
          type="button"
          disabled={confirm !== 'DELETE' || busy}
          onClick={run}
          className="px-4 py-2 bg-red-500 text-black text-[10px] font-black uppercase tracking-widest disabled:opacity-40"
        >
          {busy ? 'Deleting…' : 'Delete account'}
        </button>
        <button
          type="button"
          onClick={() => { setOpen(false); setConfirm(''); }}
          className="px-4 py-2 border border-white/20 text-[10px] font-black uppercase tracking-widest text-white/70"
        >
          Cancel
        </button>
      </div>
    </div>
  );
}
