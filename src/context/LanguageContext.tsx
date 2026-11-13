// Language context — English + Spanish (Hi.Events parity).
//
// Provides the active language + a t(key, vars) translator. Persists the choice
// to localStorage; first-load default follows the browser language (es → es,
// else en). English is the fallback for any missing key.

import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import { translate, type DictKey, type Lang } from '../lib/i18n/dict';

const STORAGE_KEY = 'exos.lang';

interface LanguageCtx {
  lang: Lang;
  setLang: (l: Lang) => void;
  t: (key: DictKey, vars?: Record<string, string | number>) => string;
}

const Ctx = createContext<LanguageCtx | null>(null);

function detectInitial(): Lang {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === 'en' || saved === 'es') return saved;
  } catch { /* ignore */ }
  const nav = (typeof navigator !== 'undefined' ? navigator.language : 'en') || 'en';
  return nav.toLowerCase().startsWith('es') ? 'es' : 'en';
}

export function LanguageProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(detectInitial);

  useEffect(() => {
    try { localStorage.setItem(STORAGE_KEY, lang); } catch { /* ignore */ }
    if (typeof document !== 'undefined') document.documentElement.lang = lang;
  }, [lang]);

  // A choice made on the switcher is also saved on a signed-in account
  // (user_metadata.lang), so mail queued later by the server, for orders
  // without a recorded language, can be in Spanish (mig 20261114130000).
  // Best effort: a failure or a signed-out visitor changes nothing.
  const setLang = useCallback((l: Lang) => {
    setLangState(l);
    void (async () => {
      try {
        const { supabase } = await import('../lib/supabase');
        const { data } = await supabase.auth.getSession();
        if (data.session && data.session.user.user_metadata?.lang !== l) await supabase.auth.updateUser({ data: { lang: l } });
      } catch { /* not signed in, or offline */ }
    })();
  }, []);

  const t = useCallback<LanguageCtx['t']>((key, vars) => translate(lang, key, vars), [lang]);

  return <Ctx.Provider value={{ lang, setLang, t }}>{children}</Ctx.Provider>;
}

// Outside a LanguageProvider (a component rendered on its own, in a test or
// an embed): English, and the switch does nothing.
const ENGLISH: LanguageCtx = { lang: 'en', setLang: () => {}, t: (key, vars) => translate('en', key, vars) };

export function useLanguage(): LanguageCtx {
  return useContext(Ctx) ?? ENGLISH;
}

/** Convenience hook — just the translator. */
export function useT() {
  return useLanguage().t;
}
