import { useEffect, useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { Settings } from 'lucide-react';
import { Link, useLocation } from 'react-router-dom';
import DeleteAccountPanel from '../components/DeleteAccountPanel';
import AccountSecurityPanel from '../components/AccountSecurityPanel';
import { useToast } from '../context/ToastContext';
import { unfollowOrg } from '../lib/orgs';
import { DISPLAY_NAME_MAX, listFollowedOrgs, updateDisplayName, type FollowedOrg } from '../lib/profile';

export default function Profile() {
  const { user } = useAuth();
  const { hash } = useLocation();
  const { toast } = useToast();
  // Followed organizers (null while loading).
  const [follows, setFollows] = useState<FollowedOrg[] | null>(null);
  const [unfollowing, setUnfollowing] = useState<string | null>(null);
  // Display-name editor: the draft while open, else null.
  const [nameDraft, setNameDraft] = useState<string | null>(null);
  const [savingName, setSavingName] = useState(false);

  const uid = user?.uid;
  useEffect(() => {
    if (!uid) return undefined;
    let alive = true;
    listFollowedOrgs()
      .then((rows) => { if (alive) setFollows(rows); })
      .catch(() => { if (alive) setFollows([]); });
    return () => { alive = false; };
  }, [uid]);

  const unfollow = async (org: FollowedOrg) => {
    setUnfollowing(org.id);
    try {
      await unfollowOrg(org.id);
      setFollows((cur) => (cur ?? []).filter((o) => o.id !== org.id));
      toast({ kind: 'success', message: `Unfollowed ${org.name}.` });
    } catch {
      toast({ kind: 'error', message: 'Could not unfollow. Try again.' });
    } finally {
      setUnfollowing(null);
    }
  };

  const saveName = async () => {
    if (!user || nameDraft === null) return;
    setSavingName(true);
    try {
      await updateDisplayName(user.uid, nameDraft);
      setNameDraft(null);
      toast({ kind: 'success', message: 'Name saved.' });
    } catch (err) {
      toast({ kind: 'error', message: (err as Error)?.message || 'Could not save your name.' });
    } finally {
      setSavingName(false);
    }
  };

  // /profile#account (linked from /reset-password and the settings list).
  useEffect(() => {
    if (user && hash === '#account') document.getElementById('account')?.scrollIntoView();
  }, [user, hash]);

  if (!user) {
    return (
      <div className="max-w-7xl mx-auto p-20 text-center font-bold text-white/40 type uppercase tracking-widest text-xs">
        Please sign in to view your profile.
      </div>
    );
  }

  const initial = (user.displayName?.charAt(0) || user.email?.charAt(0) || '?').toUpperCase();
  const displayName = (user.displayName || user.email?.split('@')[0] || 'Pass Holder');

  return (
    <div className="wall d4-grain min-h-screen text-white pb-20">
      {/* Bespoke film-grain overlay (from the Profile mockup; not in index.css). */}
      <style>{`
        .d4-grain::before {
          content: "";
          position: fixed;
          inset: 0;
          z-index: 1;
          pointer-events: none;
          opacity: .055;
          mix-blend-mode: overlay;
          background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
        }
      `}</style>

      <div className="max-w-4xl mx-auto px-4 py-12 relative z-10">

        {/* Header */}
        <div className="flex items-center gap-6 mb-12">
          <div className="w-24 h-24 bg-brand-primary flex items-center justify-center disp text-5xl text-black">
            {initial}
          </div>
          <div className="min-w-0">
            {nameDraft === null ? (
              <>
                <h1 className="disp text-4xl md:text-5xl tracking-tight leading-none uppercase break-words" style={{ transform: 'skewX(-4deg)' }}>
                  {displayName}
                </h1>
                <button
                  type="button"
                  onClick={() => setNameDraft(user.displayName ?? '')}
                  className="type text-[11px] uppercase tracking-widest text-white/60 hover:text-brand-primary mt-3"
                >
                  {user.displayName ? 'Change name' : 'Add your name'}
                </button>
              </>
            ) : (
              <form onSubmit={(e) => { e.preventDefault(); void saveName(); }} className="flex flex-wrap items-center gap-2">
                <label htmlFor="profile-name" className="sr-only">Your name</label>
                <input
                  id="profile-name"
                  autoFocus
                  value={nameDraft}
                  maxLength={DISPLAY_NAME_MAX}
                  autoComplete="name"
                  onChange={(e) => setNameDraft(e.target.value)}
                  className="type bg-black border border-white/20 px-3 py-2 text-white text-sm focus:border-brand-primary outline-none"
                />
                <button type="submit" disabled={savingName} className="type text-[11px] uppercase tracking-widest bg-brand-primary text-black px-4 py-2 disabled:opacity-50">
                  {savingName ? 'Saving…' : 'Save'}
                </button>
                <button type="button" onClick={() => setNameDraft(null)} className="type text-[11px] uppercase tracking-widest text-white/60 hover:text-white px-2 py-2">
                  Cancel
                </button>
              </form>
            )}
            <p className="type text-white/40 text-[10px] uppercase tracking-widest mt-2">pass holder // general access</p>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">

          {/* Main Content */}
          <div className="md:col-span-2 space-y-8">

            {/* Following (Friends removed per Kanban) */}
            <div className="bg-[#111] border border-white/10 p-8">
              <h2 className="disp text-2xl md:text-3xl tracking-tight mb-6 uppercase" style={{ transform: 'skewX(-4deg)' }}>
                Following Organizers
              </h2>
              {follows === null ? (
                <p className="type text-white/40 text-[12px] uppercase tracking-widest animate-pulse">loading…</p>
              ) : follows.length === 0 ? (
                <div className="text-center py-14 border border-white/5 border-dashed">
                  <p className="type text-white/30 mb-4 text-[13px] uppercase tracking-widest">your following list is empty</p>
                  <Link
                    to="/"
                    className="disp inline-block px-6 py-2 bg-white text-black text-lg tracking-wide hover:bg-brand-primary transition-colors uppercase"
                  >
                    Find Events
                  </Link>
                </div>
              ) : (
                <ul className="divide-y divide-white/10 border-y border-white/10">
                  {follows.map((o) => (
                    <li key={o.id} className="flex items-center justify-between gap-4 py-3">
                      <Link to={`/organizer/${o.id}`} className="min-w-0 hover:text-brand-primary transition-colors">
                        <span className="disp text-xl tracking-tight uppercase block truncate">{o.name}</span>
                        <span className="type text-[10px] text-white/40 uppercase tracking-widest">
                          {o.followers} follower{o.followers === 1 ? '' : 's'}
                        </span>
                      </Link>
                      <button
                        type="button"
                        onClick={() => void unfollow(o)}
                        disabled={unfollowing === o.id}
                        className="type shrink-0 text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/70 hover:border-brand-accent hover:text-brand-accent disabled:opacity-40"
                      >
                        {unfollowing === o.id ? 'Unfollowing…' : 'Unfollow'}
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            <AccountSecurityPanel />

          </div>

          {/* Sidebar */}
          <div className="space-y-4">
            <Link to="/my-tickets" className="block w-full p-6 bg-brand-primary text-black hover:bg-white transition-colors group">
              <h3 className="disp text-2xl tracking-tight uppercase">My Vault</h3>
              <p className="type text-[10px] uppercase tracking-widest opacity-70 group-hover:opacity-100 transition-all">access your passes</p>
            </Link>

            <div className="bg-[#111] border border-white/10 p-6">
              <div className="flex items-center gap-2 mb-4 text-white/40">
                <Settings className="w-4 h-4" />
                <span className="type text-[10px] uppercase tracking-widest">settings</span>
              </div>
              <ul className="space-y-3">
                <li><a href="#account" onClick={(e) => { e.preventDefault(); document.getElementById('account')?.scrollIntoView({ behavior: 'smooth' }); }} className="type text-[12px] uppercase tracking-widest text-white hover:text-brand-primary transition-colors">account &amp; security</a></li>
                <li><Link to="/privacy" className="type text-[12px] uppercase tracking-widest text-white hover:text-brand-primary transition-colors">privacy</Link></li>
              </ul>
              <div className="mt-6 pt-4 border-t border-white/10">
                <DeleteAccountPanel />
              </div>
            </div>
          </div>

        </div>

      </div>
    </div>
  );
}
