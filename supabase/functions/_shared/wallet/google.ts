// Google Wallet event tickets: EventTicketClass (one per event) and
// EventTicketObject (one per pass) with a TOTP rotatingBarcode, the Wallet
// REST calls that store them, and the "Save to Google Wallet" JWT.
//
// The object is inserted server-to-server and the save JWT only names its id
// ("skinny" JWT), so the TOTP key never appears in a URL the holder's browser
// sees or could leak. Google gets a key derived from barcode_secret
// (codes.ts / _exos_wallet_google_key), never the secret itself.
//
// Signing (RS256, the service account key) is injected, so everything here is
// testable with a fake signer; fetch is injected for the REST calls.

import { fromBase64Url, toBase64Url, utf8 } from "./bytes.ts";
import { importRsaSigningKey, rsaSign, WalletKeyError } from "./keys.ts";
import { TOTP_DIGITS, TOTP_PERIOD_MS } from "./codes.ts";
import { displayState, localIso, shortTicket, VOID_TEXT, type WalletPayload } from "./payload.ts";

export const WALLET_API = "https://walletobjects.googleapis.com/walletobjects/v1";
export const OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const WALLET_SCOPE = "https://www.googleapis.com/auth/wallet_object.issuer";

export interface Rs256Signer {
  /** Service account email (the JWT issuer). */
  email: string;
  sign(data: Uint8Array): Promise<Uint8Array>;
}

const loc = (value: string) => ({ defaultValue: { language: "en-US", value } });

const ID_RE = /^[0-9]+$/;

export function classId(issuerId: string, eventId: string): string {
  if (!ID_RE.test(issuerId)) throw new Error("issuer id must be numeric");
  return `${issuerId}.exos-event-${eventId}`;
}

export function objectId(issuerId: string, serial: string): string {
  if (!ID_RE.test(issuerId)) throw new Error("issuer id must be numeric");
  return `${issuerId}.exos-pass-${serial}`;
}

export function buildEventTicketClass(p: WalletPayload, issuerId: string): Record<string, unknown> {
  const ev = p.event;
  const cls: Record<string, unknown> = {
    id: classId(issuerId, ev.id),
    issuerName: (p.org_name || "Exos").slice(0, 60),
    eventName: loc(ev.name),
    reviewStatus: "UNDER_REVIEW",
    hexBackgroundColor: "#111827",
    multipleDevicesAndHoldersAllowedStatus: "ONE_USER_ALL_DEVICES",
  };
  if (ev.venue_name || ev.venue_location) {
    cls.venue = {
      name: loc(ev.venue_name || ev.venue_location || ""),
      address: loc(ev.venue_location || ev.venue_name || ""),
    };
  }
  if (ev.starts_at) {
    const dt: Record<string, string> = { start: localIso(ev.starts_at, ev.timezone) };
    if (ev.ends_at) dt.end = localIso(ev.ends_at, ev.timezone);
    if (ev.doors_at) dt.doorsOpen = localIso(ev.doors_at, ev.timezone);
    cls.dateTime = dt;
  }
  if (typeof ev.lat === "number" && typeof ev.lng === "number") {
    cls.locations = [{ latitude: ev.lat, longitude: ev.lng }];
  }
  return cls;
}

export function buildEventTicketObject(p: WalletPayload, issuerId: string): Record<string, unknown> {
  const state = displayState(p);
  const obj: Record<string, unknown> = {
    id: objectId(issuerId, p.serial),
    classId: classId(issuerId, p.event.id),
    state: state === "void" ? "INACTIVE" : state === "checked-in" ? "COMPLETED" : "ACTIVE",
    ticketNumber: shortTicket(p.ticket.id),
    hexBackgroundColor: "#111827",
  };
  if (p.ticket.attendee_name) obj.ticketHolderName = p.ticket.attendee_name;
  if (p.ticket.tier_name) obj.ticketType = loc(p.ticket.tier_name);
  if (p.ticket.section_label) obj.seatInfo = { section: loc(p.ticket.section_label) };
  if (state === "void") {
    obj.textModulesData = [{
      id: "void", header: "Void",
      body: VOID_TEXT[p.void_reason ?? ""] ?? VOID_TEXT["ticket-voided"],
    }];
  } else if (p.google_key_hex) {
    obj.rotatingBarcode = googleRotatingBarcode(p.google_pattern, p.google_key_hex, shortTicket(p.ticket.id));
  }
  if (p.event.ends_at) {
    obj.validTimeInterval = { end: { date: localIso(new Date(new Date(p.event.ends_at).getTime() + 12 * 3600_000).toISOString(), p.event.timezone) } };
  }
  return obj;
}

/** Google's TOTP rotating barcode. The key is hex (Base16), as Google expects. */
export function googleRotatingBarcode(valuePattern: string, keyHex: string, alternateText?: string): Record<string, unknown> {
  if (!/^[0-9a-f]{40}$/.test(keyHex)) throw new Error("TOTP key must be 20 bytes of hex");
  if (!valuePattern.includes("{totp_value_0}")) throw new Error("valuePattern needs {totp_value_0}");
  return {
    type: "QR_CODE",
    renderEncoding: "UTF_8",
    valuePattern,
    totpDetails: {
      periodMillis: String(TOTP_PERIOD_MS),
      algorithm: "TOTP_SHA1",
      parameters: [{ key: keyHex, valueLength: TOTP_DIGITS }],
    },
    ...(alternateText ? { alternateText } : {}),
  };
}

// ── JWTs ──────────────────────────────────────────────────────────────────

export async function signJwt(claims: Record<string, unknown>, signer: Rs256Signer): Promise<string> {
  const head = toBase64Url(utf8(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const body = toBase64Url(utf8(JSON.stringify(claims)));
  const sig = await signer.sign(utf8(`${head}.${body}`));
  return `${head}.${body}.${toBase64Url(sig)}`;
}

/** Claims of a "Save to Google Wallet" JWT that references stored objects by id. */
export function saveJwtClaims(opts: {
  issuerEmail: string;
  objectIds: string[];
  origins?: string[];
  iat?: number;
}): Record<string, unknown> {
  return {
    iss: opts.issuerEmail,
    aud: "google",
    typ: "savetowallet",
    iat: opts.iat ?? Math.floor(Date.now() / 1000),
    origins: opts.origins ?? [],
    payload: { eventTicketObjects: opts.objectIds.map((id) => ({ id })) },
  };
}

export async function buildSaveUrl(signer: Rs256Signer, objectIds: string[], origins?: string[], iat?: number): Promise<string> {
  const jwt = await signJwt(saveJwtClaims({ issuerEmail: signer.email, objectIds, origins, iat }), signer);
  return `https://pay.google.com/gp/v/save/${jwt}`;
}

export function decodeJwt(jwt: string): { header: Record<string, unknown>; claims: Record<string, unknown>; signature: string } {
  const [h, c, s] = jwt.split(".");
  const dec = (x: string) => JSON.parse(new TextDecoder().decode(fromBase64Url(x)));
  return { header: dec(h), claims: dec(c), signature: s };
}

/** The real signer, from the service account's JSON key. */
export async function createRs256Signer(serviceAccountJson: string): Promise<Rs256Signer> {
  let sa: { client_email?: unknown; private_key?: unknown };
  try {
    sa = JSON.parse(serviceAccountJson);
  } catch {
    throw new WalletKeyError("service account key is not JSON");
  }
  if (typeof sa.client_email !== "string" || typeof sa.private_key !== "string") {
    throw new WalletKeyError("service account key lacks client_email / private_key");
  }
  const key = await importRsaSigningKey(sa.private_key);
  return { email: sa.client_email, sign: (data) => rsaSign(key, data) };
}

// ── Wallet REST (server to server) ─────────────────────────────────────────

export type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

export async function googleAccessToken(signer: Rs256Signer, fetchFn: FetchLike, nowSec = Math.floor(Date.now() / 1000)): Promise<string> {
  const assertion = await signJwt({
    iss: signer.email, scope: WALLET_SCOPE, aud: OAUTH_TOKEN_URL, iat: nowSec, exp: nowSec + 3600,
  }, signer);
  const res = await fetchFn(OAUTH_TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }).toString(),
  });
  if (!res.ok) throw new Error(`google oauth: HTTP ${res.status}`);
  const j = await res.json();
  if (typeof j?.access_token !== "string") throw new Error("google oauth: no access_token");
  return j.access_token;
}

/** Insert, or replace when it already exists (409). */
export async function upsertResource(
  fetchFn: FetchLike,
  token: string,
  kind: "eventTicketClass" | "eventTicketObject",
  body: Record<string, unknown>,
): Promise<"inserted" | "updated"> {
  const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
  const ins = await fetchFn(`${WALLET_API}/${kind}`, { method: "POST", headers, body: JSON.stringify(body) });
  if (ins.ok) return "inserted";
  if (ins.status !== 409) throw new Error(`google ${kind} insert: HTTP ${ins.status}`);
  const id = encodeURIComponent(String(body.id));
  // Class: PATCH keeps Google's review state; object: PUT replaces it whole.
  const method = kind === "eventTicketClass" ? "PATCH" : "PUT";
  const upd = await fetchFn(`${WALLET_API}/${kind}/${id}`, { method, headers, body: JSON.stringify(body) });
  if (!upd.ok) throw new Error(`google ${kind} update: HTTP ${upd.status}`);
  return "updated";
}

/** Store the class + object for a pass and return its save link. */
export async function googleSaveLink(
  p: WalletPayload,
  cfg: { issuerId: string; origins?: string[] },
  signer: Rs256Signer,
  fetchFn: FetchLike,
): Promise<string> {
  const token = await googleAccessToken(signer, fetchFn);
  await upsertResource(fetchFn, token, "eventTicketClass", buildEventTicketClass(p, cfg.issuerId));
  const obj = buildEventTicketObject(p, cfg.issuerId);
  await upsertResource(fetchFn, token, "eventTicketObject", obj);
  return buildSaveUrl(signer, [String(obj.id)], cfg.origins);
}
