// One-click unsubscribe for marketing mail (RFC 8058). exos-mail-drain sends
//   List-Unsubscribe: <…/functions/v1/exos-mail-unsubscribe?t=<token>>
//   List-Unsubscribe-Post: List-Unsubscribe=One-Click
// and the mail client's Unsubscribe button POSTs here. No imports, so the
// Deno test loads it without the Supabase client.
//
//   POST ?t=<token>   unsubscribes (exos_mail_unsubscribe) and answers 200, the
//                     same whether or not the token matched (nothing to probe).
//   GET  ?t=<token>   never unsubscribes (link scanners fetch links): 303 to
//                     the app's /unsubscribe page, or a one-button form when
//                     EXOS_APP_URL isn't set.

const TOKEN = /^[0-9a-f]{64}$/;

export interface UnsubscribeDeps {
  /** Calls exos_mail_unsubscribe; throws if the database can't be reached. */
  unsubscribe(token: string): Promise<void>;
  /** normalizeAppUrl(EXOS_APP_URL), or null. */
  appUrl: string | null;
}

export async function handleUnsubscribe(req: Request, deps: UnsubscribeDeps): Promise<Response> {
  const token = new URL(req.url).searchParams.get("t") ?? "";
  if (!TOKEN.test(token)) return text("not a valid unsubscribe link", 400);

  if (req.method === "POST") {
    try {
      await deps.unsubscribe(token);
    } catch (_) {
      // 5xx so the mail client may try again.
      return text("could not unsubscribe right now, try again later", 503);
    }
    return text("You're unsubscribed. You won't get emails like this one again.", 200);
  }
  if (req.method === "GET" || req.method === "HEAD") {
    if (deps.appUrl) {
      return new Response(null, {
        status: 303,
        headers: { location: `${deps.appUrl}/unsubscribe?t=${token}`, "cache-control": "no-store" },
      });
    }
    return new Response(
      `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
        `<title>Unsubscribe</title><form method="post"><p>Stop follow-up emails like this one?</p>` +
        `<button type="submit">Unsubscribe</button></form>`,
      { status: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
    );
  }
  return text("method not allowed", 405);
}

function text(body: string, status: number): Response {
  return new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
}
