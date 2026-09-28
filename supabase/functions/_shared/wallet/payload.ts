// The pass data the database hands the edge function
// (exos_wallet_pass_payload / exos_wallet_fetch_pass, mig 20260929072000).
// Holder-safe by construction: no email, no price, no buyer id, and no
// barcode_secret (the door code and TOTP key are derived in SQL).

export interface WalletPayload {
  serial: string;
  pass_type: string | null;
  status: "active" | "voided";
  void_reason: string | null;
  code_epoch: number;
  updated_at: string;
  ticket: {
    id: string;
    status: string;
    tier_name: string | null;
    section_label: string | null;
    attendee_name: string | null;
    in_transfer: boolean;
    check_in_at: string | null;
  };
  event: {
    id: string;
    name: string;
    status: string | null;
    starts_at: string | null;
    ends_at: string | null;
    doors_at: string | null;
    timezone: string | null;
    venue_name: string | null;
    venue_location: string | null;
    lat: number | null;
    lng: number | null;
  };
  org_name: string | null;
  /** W-…:a{epoch}:… — null once the pass is voided. */
  apple_code: string | null;
  /** 20-byte TOTP key, hex — null once the pass is voided. */
  google_key_hex: string | null;
  google_pattern: string;
}

/** What the holder sees about the pass's state. */
export type PassDisplayState = "valid" | "checked-in" | "in-transfer" | "void";

export function displayState(p: WalletPayload): PassDisplayState {
  if (p.status === "voided" || p.ticket.status === "voided" || !p.apple_code) return "void";
  if (p.ticket.status === "used") return "checked-in";
  if (p.ticket.in_transfer) return "in-transfer";
  return "valid";
}

export const VOID_TEXT: Record<string, string> = {
  "transferred": "This ticket was transferred to someone else.",
  "ticket-voided": "This ticket was cancelled or refunded.",
  "released": "This ticket was released.",
};

/**
 * An ISO timestamp rendered in the event's own time zone with its offset
 * ("2026-10-02T20:00:00-04:00"), so a wallet shows the local start time
 * wherever the phone is. Unknown / missing zone: UTC ("Z").
 */
export function localIso(isoUtc: string, timeZone: string | null | undefined): string {
  const d = new Date(isoUtc);
  if (Number.isNaN(d.getTime())) throw new Error("bad date");
  const ms = Math.floor(d.getTime() / 1000) * 1000;
  let offsetMin = 0;
  if (timeZone) {
    try {
      const parts = new Intl.DateTimeFormat("en-US", {
        timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
        hour: "2-digit", minute: "2-digit", second: "2-digit",
      }).formatToParts(new Date(ms));
      const get = (t: string) => Number(parts.find((p) => p.type === t)?.value);
      const asUtc = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
      offsetMin = Math.round((asUtc - ms) / 60000);
    } catch {
      offsetMin = 0;
    }
  }
  const local = new Date(ms + offsetMin * 60000).toISOString().slice(0, 19);
  if (offsetMin === 0) return `${local}Z`;
  const sign = offsetMin < 0 ? "-" : "+";
  const a = Math.abs(offsetMin);
  return `${local}${sign}${String(Math.floor(a / 60)).padStart(2, "0")}:${String(a % 60).padStart(2, "0")}`;
}

/** Last 8 characters of the ticket id, as shown on the pass. */
export const shortTicket = (id: string): string => id.replace(/-/g, "").slice(-8).toUpperCase();
