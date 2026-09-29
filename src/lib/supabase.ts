import { createClient } from '@supabase/supabase-js';

// Supabase client for Exos (D4). Replaces the Firebase/Firestore data layer
// — migration in progress, see docs/d4_bridge_charter.md. The anon key is a
// public client identifier (like the Firebase web apiKey); row access is
// enforced by RLS on the exos_* tables, not by hiding this key.
//
// Env access mirrors src/lib/stripe.ts: `(import.meta as any).env` so we don't
// need a vite/client type reference in tsconfig.
const url = (import.meta as any).env?.VITE_SUPABASE_URL as string | undefined;
const anonKey = (import.meta as any).env?.VITE_SUPABASE_ANON_KEY as string | undefined;

if (!url || !anonKey) {
  console.warn(
    'VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY not set — Supabase calls will fail.',
  );
}

// The URL the page was opened with, captured before the client below reads
// and clears the auth params (it wipes #access_token… once it has stored the
// session). /auth/callback and /reset-password read it to tell a recovery or
// email-change link from a plain visit, and to show link errors.
export const initialAuthUrl = typeof window !== 'undefined' ? window.location.href : '';

export const supabase = createClient(url ?? '', anonKey ?? '', {
  auth: {
    // Persist the session in localStorage and refresh it transparently so
    // organizers/buyers stay signed in across reloads (parity with Firebase
    // Auth's persistence).
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    // flowType stays at the supabase-js default, 'implicit': email links land
    // with #access_token… and work on any device. PKCE ('?code=') would tie
    // each email link to the browser that asked for it. /auth/callback and
    // /reset-password still handle ?code= and ?token_hash= links.
  },
});
