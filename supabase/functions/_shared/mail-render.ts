// Last-mile rendering for queued exos_mail rows, used by exos-mail-drain.
//
// Mail bodies are rendered in SQL when they're queued, but SQL doesn't know
// the app's public URL. Rows that link back into the app (checkout-abandoned:
// "finish your order", unsubscribe) carry the literal {{app_url}} placeholder,
// filled here from EXOS_APP_URL (e.g. https://host/bridge, no trailing slash
// needed). A row with a placeholder and no configured URL is refused rather
// than sent with dead links. No imports, so Deno and EXP's vitest both load it.

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

export function renderMail(
  html: string,
  listUnsubscribe: string | null | undefined,
  appUrl: string | null,
): RenderedMail {
  const needsUrl = html.includes(APP_URL_TOKEN) || (listUnsubscribe ?? "").includes(APP_URL_TOKEN);
  if (needsUrl && !appUrl) {
    return { ok: false, error: "EXOS_APP_URL unset or invalid; mail links into the app" };
  }
  const fill = (s: string) => (appUrl ? s.split(APP_URL_TOKEN).join(appUrl) : s);
  const headers: Record<string, string> = {};
  const unsub = listUnsubscribe ? fill(listUnsubscribe) : "";
  if (/^https?:\/\/[^\s<>]+$/.test(unsub)) headers["List-Unsubscribe"] = `<${unsub}>`;
  return { ok: true, html: fill(html), headers };
}

/**
 * A text message that links into the app (the weekly channel report text,
 * mig 20261029120000) carries {{app_url}} like a mail row. Returns the filled
 * text, or null when it needs the URL and none is configured: such a text is
 * held back, not sent with a dead link.
 */
export function fillAppUrl(text: string, appUrl: string | null): string | null {
  if (!text.includes(APP_URL_TOKEN)) return text;
  return appUrl ? text.split(APP_URL_TOKEN).join(appUrl) : null;
}
