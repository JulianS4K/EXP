// Masked SMS relay for group chats (mig 20261031230000, docs/group-chat.md).
// Pure helpers shared by exos-sms-relay (Deno) and the app (src/lib/groupChat.ts):
// keyword classification, what a relayed text looks like, parsing each
// provider's inbound webhook, and the platform sender config.

import type { SmsConfig } from "./providers.ts";

export type RelayKeyword = "stop" | "stop_all" | "start" | "help";
export type RelayProvider = "twilio" | "telnyx";

const STOP_WORDS = new Set(["STOP", "UNSUBSCRIBE", "CANCEL", "END", "QUIT", "OPTOUT", "OPT OUT", "REVOKE", "STOPP"]);
const STOP_ALL_WORDS = new Set(["STOPALL", "STOP ALL"]);
// No "YES": in a group chat "yes" is a message, not a keyword.
const START_WORDS = new Set(["START", "UNSTOP", "RESUME"]);
const HELP_WORDS = new Set(["HELP", "INFO"]);

/**
 * The carrier keyword a whole text is, or null for an ordinary message. Case,
 * punctuation and extra spaces don't matter ("Stop.", " stop all ").
 * STOP on a pool number leaves that group's relay; STOPALL leaves every group.
 */
export function relayKeyword(text: string | null | undefined): RelayKeyword | null {
  const w = String(text ?? "").replace(/[^A-Za-z ]/g, "").replace(/\s+/g, " ").trim().toUpperCase();
  if (!w || w.length > 12) return null;
  if (STOP_ALL_WORDS.has(w)) return "stop_all";
  if (STOP_WORDS.has(w)) return "stop";
  if (START_WORDS.has(w)) return "start";
  if (HELP_WORDS.has(w)) return "help";
  return null;
}

const LINK = /(https?:\/\/|www\.)\S+/gi;
export const RELAY_MAX_CHARS = 306; // two GSM-7 segments

/** First name shown on relayed texts: letters, digits, space . ' - only; "Member" if empty. */
export function relayFirstName(name: string | null | undefined): string {
  const s = String(name ?? "").replace(/[^A-Za-z0-9 .'-]/g, "").replace(/\s+/g, " ").trim();
  return (s.split(" ")[0] || "Member").slice(0, 20);
}

/**
 * "<first name>: <text>" with links replaced by "[link in app]" (relayed texts
 * from a shared number shouldn't carry links), whitespace collapsed, at most
 * 306 characters. Must match exos_relay_format() in the migration (the SQL
 * builds the outbox row; this is the app's preview and the tests' oracle).
 */
export function formatRelayBody(name: string | null | undefined, body: string | null | undefined): string {
  const text = String(body ?? "").replace(LINK, "[link in app]").replace(/\s+/g, " ").trim();
  const full = `${relayFirstName(name)}: ${text}`;
  const chars = Array.from(full);
  return chars.length > RELAY_MAX_CHARS ? chars.slice(0, RELAY_MAX_CHARS - 3).join("") + "..." : full;
}

/** The consent line a member ticks before getting relayed texts (stored with the opt-in). */
export function relayConsentText(groupTitle: string): string {
  return `Text me "${groupTitle.slice(0, 40)}" group messages at this number from an Exos number (my own number stays hidden). ` +
    "Msg frequency varies. Msg & data rates may apply. Reply STOP to cancel, HELP for help. Consent is not a condition of purchase.";
}

const E164 = /^\+[1-9][0-9]{7,14}$/;

/** +E.164, or null (US / CA 10 or 11 digits without a + are accepted). */
export function e164(raw: unknown): string | null {
  const s = String(raw ?? "").replace(/[^0-9+]/g, "");
  if (E164.test(s)) return s;
  if (/^[2-9][0-9]{9}$/.test(s)) return `+1${s}`;
  if (/^1[2-9][0-9]{9}$/.test(s)) return `+${s}`;
  return null;
}

export interface RelayInbound { from: string; to: string; text: string; id: string | null }

/** A Twilio inbound SMS webhook (form fields From, To, Body, MessageSid). */
export function parseTwilioRelay(params: Record<string, string>): RelayInbound | null {
  const from = e164(params.From);
  const to = e164(params.To);
  if (!from || !to) return null;
  const id = typeof params.MessageSid === "string" && /^[A-Za-z0-9]{10,64}$/.test(params.MessageSid) ? params.MessageSid : null;
  return { from, to, text: String(params.Body ?? ""), id };
}

/** A Telnyx message.received event (data.payload.from.phone_number, to[0].phone_number, text, id). */
export function parseTelnyxRelay(body: any): RelayInbound | null {
  if (body?.data?.event_type !== "message.received") return null;
  const p = body.data.payload ?? {};
  const from = e164(p?.from?.phone_number);
  const toRaw = Array.isArray(p?.to) ? p.to[0]?.phone_number : p?.to?.phone_number ?? p?.to;
  const to = e164(toRaw);
  if (!from || !to) return null;
  const id = typeof p.id === "string" && p.id.length <= 80 ? `telnyx:${p.id}` : null;
  return { from, to, text: typeof p.text === "string" ? p.text : "", id };
}

/** Which inbound route a request path is: /exos-sms-relay/inbound/<provider>, /cron, or nothing. */
export function relayRoute(pathname: string): { kind: "inbound"; provider: RelayProvider } | { kind: "cron" } | null {
  const parts = pathname.replace(/\/+$/, "").split("/");
  const last = parts.pop() ?? "";
  const parent = parts.pop() ?? "";
  if (last === "cron") return { kind: "cron" };
  if (parent === "inbound" && (last === "twilio" || last === "telnyx")) return { kind: "inbound", provider: last };
  return null;
}

type Env = (k: string) => string | undefined;

/**
 * The platform's own sending account for a pool number. Twilio needs
 * EXOS_RELAY_TWILIO_ACCOUNT_SID + EXOS_RELAY_TWILIO_AUTH_TOKEN; Telnyx needs
 * EXOS_RELAY_TELNYX_API_KEY (optional EXOS_RELAY_TELNYX_PROFILE_ID).
 */
export function relaySenderConfig(provider: string, from: string, env: Env): SmsConfig | null {
  if (provider === "twilio") {
    const sid = env("EXOS_RELAY_TWILIO_ACCOUNT_SID") ?? "";
    const token = env("EXOS_RELAY_TWILIO_AUTH_TOKEN") ?? "";
    if (!sid || !token) return null;
    return { provider: "twilio", config: { account_sid: sid, from }, secret: token };
  }
  if (provider === "telnyx") {
    const key = env("EXOS_RELAY_TELNYX_API_KEY") ?? "";
    if (!key) return null;
    const profile = env("EXOS_RELAY_TELNYX_PROFILE_ID");
    return { provider: "telnyx", config: profile ? { from, messaging_profile_id: profile } : { from }, secret: key };
  }
  return null;
}

/** The relay sends real texts only with EXOS_SMS_RELAY=on; anything else is a dry run. */
export function relayLive(env: Env): boolean {
  return env("EXOS_SMS_RELAY") === "on";
}
