// Last-mile rendering for queued exos_mail rows, used by exos-mail-drain.
//
// Mail bodies are rendered in SQL when they're queued, but SQL doesn't know
// the app's public URL. Rows that link back into the app (checkout-abandoned:
// "finish your order", unsubscribe) carry the literal {{app_url}} placeholder,
// filled here from EXOS_APP_URL (e.g. https://host/bridge, no trailing slash
// needed). A row with a placeholder and no configured URL is refused rather
// than sent with dead links. No imports, so Deno and EXP's vitest both load it.
//
// One-click unsubscribe (RFC 8058; Gmail / Yahoo bulk-sender rule): with the
// exos-mail-unsubscribe endpoint's URL, an app unsubscribe link becomes
// List-Unsubscribe: <endpoint?t=token> plus List-Unsubscribe-Post, so the
// mail client's button unsubscribes with one POST. A GET of the endpoint only
// redirects to the app page, so link scanners can't unsubscribe anyone.

export const APP_URL_TOKEN = "{{app_url}}";

export type RenderedMail =
  | { ok: true; html: string; headers: Record<string, string> }
  | { ok: false; error: string };

export function normalizeAppUrl(raw: string | undefined | null): string | null {
  const s = (raw ?? "").trim().replace(/\/+$/, "");
  if (!s) return null;
  let u: URL;
  try { u = new URL(s); } catch { return null; }
  if (u.username || u.password || u.search || u.hash) return null;
  const local = u.hostname === "localhost" || u.hostname === "127.0.0.1";
  if (u.protocol !== "https:" && !(u.protocol === "http:" && local)) return null;
  return s;
}

const APP_UNSUBSCRIBE = /\/unsubscribe\?t=([0-9a-f]{64})$/;

/** exos-mail-unsubscribe's URL from SUPABASE_URL; https only (RFC 8058). */
export function oneClickUnsubscribeUrl(supabaseUrl: string | undefined | null): string | null {
  const base = normalizeAppUrl(supabaseUrl);
  return base && base.startsWith("https://") ? `${base}/functions/v1/exos-mail-unsubscribe` : null;
}

export function renderMail(
  html: string,
  listUnsubscribe: string | null | undefined,
  appUrl: string | null,
  oneClickUrl: string | null = null,
): RenderedMail {
  const needsUrl = html.includes(APP_URL_TOKEN) || (listUnsubscribe ?? "").includes(APP_URL_TOKEN);
  if (needsUrl && !appUrl) {
    return { ok: false, error: "EXOS_APP_URL unset or invalid; mail links into the app" };
  }
  const fill = (s: string) => (appUrl ? s.split(APP_URL_TOKEN).join(appUrl) : s);
  const headers: Record<string, string> = {};
  const unsub = listUnsubscribe ? fill(listUnsubscribe) : "";
  if (/^https?:\/\/[^\s<>]+$/.test(unsub)) {
    const token = oneClickUrl ? APP_UNSUBSCRIBE.exec(unsub)?.[1] : undefined;
    if (token) {
      headers["List-Unsubscribe"] = `<${oneClickUrl}?t=${token}>`;
      headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click";
    } else {
      headers["List-Unsubscribe"] = `<${unsub}>`;
    }
  }
  return { ok: true, html: fill(html), headers };
}
