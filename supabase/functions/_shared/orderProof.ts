// Proof of email or phone before a guest's tickets are released (mig
// 20261105100000, SIM-BUYER-12/13). exos-checkout gives the paying browser a
// random token and stores only its SHA-256 on the order; the page the buyer
// paid on sends it with every exos_order_proof_* call, so a code mailed to a
// mistyped address that belongs to someone else does nothing in their hands.
// Pure (WebCrypto only), shared by exos-checkout and the SPA.

/** A 256-bit browser token, base64url (43 characters). */
export function newProofToken(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// --- The token in the return URL's fragment (#pt=) ----------------------------
// Instagram / Facebook in-app browsers can block localStorage, so the token
// the paying browser was given would be gone by the time it is back from
// Stripe or PayPal. exos-checkout therefore also puts it on the return URL,
// in the fragment: browsers never send a fragment to a server (no request
// line, no access log, no Referer), and the page strips it from the address
// bar as soon as it has read it. The token alone releases nothing: the
// 6-digit code mailed to the buyer's address (or an SMS code) is still needed,
// and 5 wrong codes lock it. Stripe and PayPal do keep the full return URL on
// their side (the Checkout Session / PayPal order), which is why the token
// alone must stay worthless.

const TOKEN_RE = /^[A-Za-z0-9_-]{20,128}$/;

/** url + #pt=<token> (or &pt= when it already has a fragment). An unusable
 *  token leaves the URL as it was. */
export function withProofFragment(url: string, token: string | null | undefined): string {
  if (!token || !TOKEN_RE.test(token)) return url;
  const i = url.indexOf("#");
  if (i < 0) return `${url}#pt=${token}`;
  const frag = url.slice(i + 1);
  return frag ? `${url}&pt=${token}` : `${url}pt=${token}`;
}

// pt= at the start of the fragment or after &, up to the next & or ?. The ?
// covers a provider that appends its query after our fragment
// (#pt=...?token=...&PayerID=...) instead of before it.
const FRAG_RE = /(^#?|&)pt=([A-Za-z0-9_-]{20,128})(?=$|[&?])/;

/** The proof token in a location.hash, or null. */
export function proofTokenFromHash(hash: string | null | undefined): string | null {
  const m = FRAG_RE.exec(hash ?? "");
  return m ? m[2] : null;
}

/** The hash with pt= taken out ("" when nothing else was in it). */
export function hashWithoutProofToken(hash: string | null | undefined): string {
  const h = (hash ?? "").replace(/^#/, "");
  const rest = h.replace(/(^|&)pt=[A-Za-z0-9_-]{20,128}(?=$|[&?])/, "").replace(/^&/, "");
  return rest ? `#${rest}` : "";
}

/** What the order stores: SHA-256 hex of the token (as the SQL checks it). */
export async function proofTokenHash(token: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token.trim()));
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** The 6 digits of a typed code (spaces and dashes ignored), or null. */
export function normalizeProofCode(raw: unknown): string | null {
  if (typeof raw !== "string" && typeof raw !== "number") return null;
  const c = String(raw).replace(/[\s-]/g, "");
  return /^[0-9]{6}$/.test(c) ? c : null;
}

export type ProofStatus = "pending" | "proven" | "cancelled" | "expired" | "unknown";

/** What the page says for each error exos_order_proof_* answers. */
export function proofErrorMessage(error: string | undefined, extra: { attempts_left?: number } = {}): string {
  switch (error) {
    case "wrong_code":
      return extra.attempts_left
        ? `That code isn't right. ${extra.attempts_left} tr${extra.attempts_left === 1 ? "y" : "ies"} left.`
        : "That code isn't right.";
    case "bad_code": return "Enter the 6-digit code.";
    case "locked": return "Too many wrong codes. Send a new code and try again.";
    case "rate_limited": return "Please wait a minute before asking for another code.";
    case "bad_phone": return "Enter a mobile number, e.g. (212) 555-0100 or +44 7700 900123.";
    case "expired": return "This order can no longer be confirmed here. Contact the organizer.";
    case "cancelled": return "This order was refunded.";
    case "unknown": return "Open this on the device and browser you paid on, or ask the organizer to resend your tickets.";
    case "proven": return "Already confirmed.";
    default: return "Something went wrong. Try again.";
  }
}

export interface ProofClaimLink { ticket_id: string; path: string }

export interface ProofState {
  status: ProofStatus;
  /** Masked: ab…@domain. */
  email?: string | null;
  phone?: string | null;
  attemptsLeft: number;
  attached: boolean;
  /** Claim links on this page (after a phone proof, no account attached). */
  tickets: ProofClaimLink[];
}


/** Only claim links (a path on this site). */
export function asProofLinks(v: unknown): ProofClaimLink[] {
  return Array.isArray(v)
    ? v.filter((x) => x && typeof x.path === "string" && x.path.startsWith("/claim/"))
        .map((x) => ({ ticket_id: String(x.ticket_id ?? ""), path: String(x.path) }))
    : [];
}

/** Map an exos_order_proof_status answer. */
export function parseProofState(d: unknown): ProofState {
  const r = (d && typeof d === "object" ? d : {}) as Record<string, unknown>;
  const st = String(r.status ?? "unknown");
  return {
    status: (["pending", "proven", "cancelled", "expired"].includes(st) ? st : "unknown") as ProofStatus,
    email: (r.email as string) ?? null,
    phone: (r.phone as string) ?? null,
    attemptsLeft: Number(r.attempts_left ?? 0) || 0,
    attached: r.attached === true,
    tickets: asProofLinks(r.tickets),
  };
}

