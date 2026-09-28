// Request routing for exos-wallet, pure so it's testable.
//
// Owner routes (Supabase JWT):
//   POST {base}/pass      { ticket_id, kind: "apple" | "google" }
//   POST {base}/reissue   { ticket_id }
// Cron (x-cron-secret):
//   POST {base}/push
// Apple PassKit web service (webServiceURL = {base}/apple), per Apple's
// "Wallet web service" reference:
//   POST   /apple/v1/devices/{device}/registrations/{passType}/{serial}   register (ApplePass auth)
//   DELETE /apple/v1/devices/{device}/registrations/{passType}/{serial}   unregister (ApplePass auth)
//   GET    /apple/v1/devices/{device}/registrations/{passType}?passesUpdatedSince=tag
//   GET    /apple/v1/passes/{passType}/{serial}                           latest pass (ApplePass auth)
//   POST   /apple/v1/log

export type WalletRoute =
  | { kind: "issue" }
  | { kind: "reissue" }
  | { kind: "push" }
  | { kind: "register"; device: string; passType: string; serial: string }
  | { kind: "unregister"; device: string; passType: string; serial: string }
  | { kind: "serials"; device: string; passType: string }
  | { kind: "latest"; passType: string; serial: string }
  | { kind: "log" }
  | { kind: "options" }
  | { kind: "not-found" };

const SEG = /^[A-Za-z0-9._-]{1,128}$/;

/** Path segments after the function name ("exos-wallet"). */
export function walletPath(pathname: string): string[] {
  const parts = pathname.split("/").filter(Boolean).map((p) => {
    try {
      return decodeURIComponent(p);
    } catch {
      return "\u0000";
    }
  });
  const i = parts.indexOf("exos-wallet");
  return i >= 0 ? parts.slice(i + 1) : parts;
}

export function routeWallet(method: string, pathname: string): WalletRoute {
  if (method === "OPTIONS") return { kind: "options" };
  const p = walletPath(pathname);
  const ok = (...xs: string[]) => xs.every((x) => SEG.test(x));
  if (p.length === 1 && method === "POST") {
    if (p[0] === "pass") return { kind: "issue" };
    if (p[0] === "reissue") return { kind: "reissue" };
    if (p[0] === "push") return { kind: "push" };
  }
  if (p[0] !== "apple" || p[1] !== "v1") return { kind: "not-found" };
  const r = p.slice(2);
  if (r.length === 1 && r[0] === "log" && method === "POST") return { kind: "log" };
  if (r[0] === "devices" && r[2] === "registrations") {
    if (r.length === 5 && ok(r[1], r[3], r[4])) {
      if (method === "POST") return { kind: "register", device: r[1], passType: r[3], serial: r[4] };
      if (method === "DELETE") return { kind: "unregister", device: r[1], passType: r[3], serial: r[4] };
    }
    if (r.length === 4 && method === "GET" && ok(r[1], r[3])) return { kind: "serials", device: r[1], passType: r[3] };
  }
  if (r[0] === "passes" && r.length === 3 && method === "GET" && ok(r[1], r[2])) {
    return { kind: "latest", passType: r[1], serial: r[2] };
  }
  return { kind: "not-found" };
}

/** HTTP-date of a timestamp, truncated to whole seconds. */
export const httpDate = (iso: string): string => new Date(Math.floor(new Date(iso).getTime() / 1000) * 1000).toUTCString();

/** True when the pass hasn't changed since the device's If-Modified-Since. */
export function notModified(updatedAtIso: string, ifModifiedSince: string | null): boolean {
  if (!ifModifiedSince) return false;
  const since = Date.parse(ifModifiedSince);
  if (Number.isNaN(since)) return false;
  return Math.floor(new Date(updatedAtIso).getTime() / 1000) * 1000 <= since;
}
