// POST to the exos-integrations edge function as the signed-in user. Split
// from ./integrations (the provider catalog) so lib/site.ts, which every page
// loads through lib/orgs.ts, doesn't bring the catalog into the first download.

import { supabase } from './supabase';

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

export async function callFn<T>(path: string, body: unknown): Promise<T> {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  if (!url) throw new Error('Integrations are not configured.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  let res: Response;
  try {
    res = await fetch(`${url}/functions/v1/exos-integrations${path}`, {
      method: 'POST',
      headers: { ...(env.VITE_SUPABASE_ANON_KEY ? { apikey: env.VITE_SUPABASE_ANON_KEY } : {}), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch {
    throw new Error("Couldn't reach Exos. Check the connection.");
  }
  const out = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(typeof out?.error === 'string' ? out.error : res.status === 404 ? 'Integrations are not deployed yet.' : `Request failed (${res.status}).`);
  }
  return out as T;
}
