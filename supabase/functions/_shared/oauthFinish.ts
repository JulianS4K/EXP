// The finish token of the OAuth sign-ins (mig 20261029140000), shared by
// exos-oauth-google (Connect Google Ads) and exos-eventbrite-oauth (Connect
// Eventbrite). No imports, so Deno and EXP's vitest both load it
// (src/lib/oauthReturn.test.ts).
//
// Why: the user who starts a sign-in knows the raw state. Without a second
// secret they could send the provider's authorize link to someone else, let
// that person sign in (their code is parked on the starter's state), and
// finish with their own JWT, attaching the other person's account to their
// org. /callback therefore mints a fresh 256-bit finish token, stores only
// its SHA-256 with the parked code, and gives the token to the returning
// browser in the URL FRAGMENT: browsers never send a fragment to a server,
// so it isn't in access logs and can't leak through a Referer. /finish needs
// the state, the finish token and the starting user's JWT.

export type FinishKey = "google_ads_finish" | "eventbrite_finish";

/** The redirect back to the app with the finish token in the fragment. */
export function withFinishFragment(url: string, key: FinishKey, token: string): string {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error("withFinishFragment: bad token");
  return `${url.split("#")[0]}#${key}=${token}`;
}

/**
 * What /finish answers when the SQL refused the state
 * (_exos_oauth_state_take's `refused`). Never echoes the state or token.
 *   other_user  started by a different Exos account: nothing was connected
 *   token       the finish token was missing or wrong (not the browser that
 *               came back from the provider)
 *   forbidden   no longer owner / manager
 *   expired     anything else (unknown, used, expired, no code)
 */
export function finishRefusal(refused: string | null | undefined): { status: number; reason: string; error: string } {
  switch (refused) {
    case "other_user":
      return { status: 403, reason: "other_user", error: "this sign-in was started by another Exos account; nothing was connected" };
    case "token":
      return { status: 400, reason: "token", error: "this sign-in can only be finished in the browser that came back from the sign-in page; nothing was connected" };
    case "forbidden":
      return { status: 403, reason: "forbidden", error: "owner or manager only" };
    default:
      return { status: 400, reason: "expired", error: "this sign-in expired or was already used; connect again" };
  }
}
