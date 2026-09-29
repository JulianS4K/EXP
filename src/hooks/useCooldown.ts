import { useCallback, useEffect, useState } from 'react';

/**
 * Seconds-left countdown for "resend" buttons. start(n) (re)arms it;
 * `left` ticks to 0 once a second. Supabase refuses repeat auth mails inside
 * ~60s anyway, so the button waits instead of hitting that wall.
 */
export function useCooldown(): { left: number; start: (seconds: number) => void } {
  const [until, setUntil] = useState(0);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (until === 0) return undefined;
    const id = setInterval(() => {
      const t = Date.now();
      setNow(t);
      if (t >= until) clearInterval(id);
    }, 1000);
    return () => clearInterval(id);
  }, [until]);

  const start = useCallback((seconds: number) => {
    const t = Date.now();
    setNow(t);
    setUntil(t + seconds * 1000);
  }, []);

  return { left: Math.max(0, Math.ceil((until - now) / 1000)), start };
}

export const RESEND_COOLDOWN_S = 60;
