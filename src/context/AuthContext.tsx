import React, { createContext, useContext, useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';
import { AppUser, toAppUser, isAdminUser, setCurrentAppUser } from '../lib/auth';
import { doorKV, forgetDoorCipher } from '../lib/door/kv';
import { wipeDoorRosters } from '../lib/door/roster';
import { signOutWarning } from '../lib/door/health';
import { pendingScanCount } from '../lib/offlineCheckins';
import AuthModal, { type AuthView } from '../components/AuthModal';

interface AuthContextType {
  user: AppUser | null;
  loading: boolean;
  // True iff the Supabase JWT carries `app_metadata.admin === true`. Set
  // server-side (service role) — unforgeable from the client, the analogue of
  // the old Firebase `admin` custom claim. Defaults to false.
  isAdmin: boolean;
  signIn: () => void; // Keeps the same method name but just opens the modal
  // Signs out this browser only.
  /** Asks first when door check-ins are still waiting to upload on this
   *  device (skipDoorCheck: account deletion, where they can't upload). */
  logout: (opts?: { skipDoorCheck?: boolean }) => Promise<void>;
  // Revokes every session the account has (all devices), then this one.
  logoutEverywhere: () => Promise<boolean>;
  // Force a session refresh so a freshly-granted app_metadata claim is picked
  // up without a sign-out/sign-in cycle.
  refreshClaims: () => Promise<void>;
  isAuthModalOpen: boolean;
  openAuthModal: () => void;
  // Opens the modal on a given screen, e.g. openAuth('code') from the claim
  // page, whose emails promise "sign in with a one-time code".
  openAuth: (view: AuthView, email?: string) => void;
  closeAuthModal: () => void;
  // True between a password-recovery link landing (PASSWORD_RECOVERY) and the
  // new password being saved; /reset-password shows its form while it is set.
  passwordRecovery: boolean;
  endPasswordRecovery: () => void;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<AppUser | null>(null);
  const [loading, setLoading] = useState(true);
  const [isAdmin, setIsAdmin] = useState(false);
  const [isAuthModalOpen, setIsAuthModalOpen] = useState(false);
  const [modalView, setModalView] = useState<AuthView>('options');
  const [modalEmail, setModalEmail] = useState('');
  const [passwordRecovery, setPasswordRecovery] = useState(false);
  const navigate = useNavigate();
  const location = useLocation();
  const navRef = useRef({ navigate, pathname: location.pathname });
  navRef.current = { navigate, pathname: location.pathname };

  useEffect(() => {
    let active = true;

    // Best-effort upsert of the user's PUBLIC profile (display-only). Email is
    // intentionally NOT mirrored — it stays on the JWT where RLS reads it, so
    // it isn't leaked to every signed-in user that reads a profile for a name.
    const syncProfile = async (u: AppUser) => {
      try {
        await supabase
          .from('exos_profiles')
          .upsert({ id: u.uid, display_name: u.displayName, photo_url: u.photoURL }, { onConflict: 'id' });
      } catch (err) {
        console.warn('Profile sync failed:', err);
      }
    };

    const apply = (session: Session | null, sync: boolean) => {
      if (!active) return;
      const su = session?.user ?? null;
      const appUser = toAppUser(su);
      setUser(appUser);
      setCurrentAppUser(appUser);
      setIsAdmin(isAdminUser(su));
      if (appUser) {
        setIsAuthModalOpen(false); // close the modal on successful login
        if (sync) void syncProfile(appUser);
      }
    };

    supabase.auth.getSession().then(({ data }) => {
      apply(data.session, true);
      if (active) setLoading(false);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      apply(session, event === 'SIGNED_IN');
      if (event === 'PASSWORD_RECOVERY') {
        // A reset link normally lands on /reset-password already; if Supabase
        // fell back to the Site URL (redirect not allow-listed), go there.
        setPasswordRecovery(true);
        const { navigate: nav, pathname } = navRef.current;
        if (pathname !== '/reset-password') nav('/reset-password', { replace: true });
      }
      if (event === 'SIGNED_OUT') setPasswordRecovery(false);
    });

    return () => {
      active = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  const refreshClaims = async () => {
    try {
      const { data } = await supabase.auth.refreshSession();
      setIsAdmin(isAdminUser(data.session?.user ?? null));
    } catch (err) {
      console.warn('Claim refresh failed:', err);
    }
  };

  const openAuth = (view: AuthView, email = '') => {
    setModalView(view);
    setModalEmail(email);
    setIsAuthModalOpen(true);
  };
  const openAuthModal = () => openAuth('options');
  const closeAuthModal = () => setIsAuthModalOpen(false);
  const signIn = () => openAuth('options'); // maintain compatibility
  const endPasswordRecovery = () => setPasswordRecovery(false);

  // supabase-js defaults signOut() to scope 'global' (every device), so the
  // plain "sign out" passes 'local' explicitly. Returns false when the server
  // refused a global sign-out (this browser is signed out regardless).
  const signOutScoped = async (scope: 'local' | 'global'): Promise<boolean> => {
    const { error } = await supabase.auth.signOut({ scope });
    if (error && scope === 'global') await supabase.auth.signOut({ scope: 'local' });
    // The door scanner caches every ticket's barcode secret + attendee names
    // for offline use; never leave that on a shared device after sign-out.
    // pending_updates_* (ticket ids only) stays so unsynced check-ins replay.
    try {
      const keys: string[] = [];
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.startsWith('registry_')) keys.push(k);
      }
      keys.forEach((k) => localStorage.removeItem(k));
    } catch {
      /* storage unavailable */
    }
    // The roster itself lives in IndexedDB (lib/door/kv).
    await wipeDoorRosters(doorKV()).catch(() => {});
    forgetDoorCipher();
    return !error;
  };

  // Door scans waiting to upload stay on the device after sign-out, but only
  // door staff of the event can upload them: say so before signing out.
  const doorScansOk = (): boolean => {
    let storage: Storage | null = null;
    try {
      storage = localStorage;
    } catch {
      return true;
    }
    const warn = signOutWarning(pendingScanCount(storage));
    return !warn || typeof window === 'undefined' || window.confirm(warn);
  };

  const logout = async (opts: { skipDoorCheck?: boolean } = {}) => {
    if (!opts.skipDoorCheck && !doorScansOk()) return;
    await signOutScoped('local');
  };
  const logoutEverywhere = () => signOutScoped('global');

  return (
    <AuthContext.Provider
      value={{
        user, loading, isAdmin, signIn, logout, logoutEverywhere, refreshClaims, isAuthModalOpen,
        openAuthModal, openAuth, closeAuthModal, passwordRecovery, endPasswordRecovery,
      }}
    >
      {children}
      <AuthModal isOpen={isAuthModalOpen} onClose={closeAuthModal} initialView={modalView} initialEmail={modalEmail} />
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
