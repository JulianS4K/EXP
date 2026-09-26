import { useEffect, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { Ticket, User, LogOut, PlusCircle, LayoutDashboard, Bell } from 'lucide-react';
import { motion } from 'motion/react';
import { useT } from '../context/LanguageContext';
import LanguageSwitcher from './LanguageSwitcher';

export default function Navbar() {
  const { user, signIn, logout } = useAuth();
  const t = useT();
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const location = useLocation();

  // The user menu opens on tap/click (hover never fires on phones) and
  // closes on navigation, an outside click or Escape.
  useEffect(() => { setMenuOpen(false); }, [location.pathname]);
  useEffect(() => {
    if (!menuOpen) return undefined;
    const onDown = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) setMenuOpen(false);
    };
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setMenuOpen(false); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [menuOpen]);

  return (
    <nav className="sticky top-0 z-50 bg-black/90 border-b border-white/10 backdrop-blur-xl">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex justify-between h-20 items-center">
          <Link to="/" className="flex items-center gap-2 sm:gap-3 group shrink-0">
            <div className="w-9 h-9 sm:w-11 sm:h-11 bg-white flex items-center justify-center transition-colors group-hover:bg-brand-primary">
              <Ticket className="text-black w-6 h-6" />
            </div>
            <span className="disp text-3xl sm:text-4xl tracking-tight text-white leading-none pt-1 group-hover:neon transition-all" style={{ transform: 'skewX(-6deg)' }}>EXOS</span>
          </Link>

          <div className="flex items-center gap-3 sm:gap-8 min-w-0">
            {/* Signed in on a phone, the switcher lives in the account menu so
                the bar fits 390px without sideways scroll. */}
            <div className={user ? 'hidden sm:block' : ''}>
              <LanguageSwitcher />
            </div>
            {user ? (
              <>
                <Link to="/my-tickets" className="type text-[11px] sm:text-[12px] uppercase tracking-wider sm:tracking-widest whitespace-nowrap text-white/60 hover:text-brand-primary transition-colors">
                  {t('nav.myTickets')}
                </Link>
                <Link to="/dashboard" aria-label={t('nav.dashboard')} className="type text-[12px] uppercase tracking-widest text-white/60 hover:text-brand-primary transition-colors flex items-center gap-2">
                  <LayoutDashboard className="w-5 h-5 sm:w-4 sm:h-4 text-brand-primary" />
                  <span className="hidden sm:inline">{t('nav.dashboard')}</span>
                </Link>
                <Link
                  to="/alerts"
                  aria-label="Alerts"
                  className="text-white/60 hover:text-brand-primary transition-colors"
                >
                  <Bell className="w-5 h-5" />
                </Link>
                <div className="relative shrink-0" ref={menuRef}>
                  <button
                    type="button"
                    aria-label="Account menu"
                    aria-haspopup="menu"
                    aria-expanded={menuOpen}
                    onClick={() => setMenuOpen((o) => !o)}
                    className="flex items-center bg-white/5 p-1 border border-white/10 hover:border-brand-primary/60 transition-colors"
                  >
                    {user.photoURL ? (
                      <img src={user.photoURL} alt="" className="w-9 h-9" />
                    ) : (
                      <span className="w-9 h-9 flex items-center justify-center text-white/70"><User className="w-5 h-5" /></span>
                    )}
                  </button>
                  <div role="menu" className={`absolute right-0 mt-2 w-56 bg-[#0e0e0e] border border-white/10 transition-all duration-200 py-2 origin-top-right shadow-2xl ${menuOpen ? 'opacity-100 visible' : 'opacity-0 invisible'}`}>
                    <div className="px-4 py-3 border-b border-white/10 mb-2">
                        <p className="type text-[9px] text-white/30 uppercase tracking-widest leading-none mb-1">Signed in as</p>
                        <p className="disp text-lg text-white uppercase truncate tracking-wide leading-none">{user.displayName || user.email}</p>
                    </div>
                    <div className="px-4 pb-2 sm:hidden">
                      <LanguageSwitcher />
                    </div>
                    <Link
                      to="/profile"
                      className="w-full text-left px-4 py-3.5 type text-[11px] uppercase tracking-widest text-white/60 hover:text-brand-primary hover:bg-white/5 flex items-center gap-3 transition-colors"
                    >
                      <User className="w-4 h-4" />
                      <span>{t('nav.profile')}</span>
                    </Link>
                    <button
                      onClick={logout}
                      className="w-full text-left px-4 py-3.5 type text-[11px] uppercase tracking-widest text-white/60 hover:text-brand-accent hover:bg-white/5 flex items-center gap-3 transition-colors"
                    >
                      <LogOut className="w-4 h-4" />
                      <span>{t('nav.signOut')}</span>
                    </button>
                  </div>
                </div>
              </>
            ) : (
              <button
                onClick={signIn}
                className="disp text-lg bg-brand-primary text-black px-5 py-1 hover:scale-[1.03] transition-transform tracking-wide"
              >
                {t('nav.signIn')}
              </button>
            )}
          </div>
        </div>
      </div>
    </nav>
  );
}
