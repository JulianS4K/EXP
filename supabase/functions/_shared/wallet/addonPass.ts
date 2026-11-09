// Add-on entry codes in Apple / Google Wallet (mig 20261108110000,
// exos_wallet_addon_pass; docs/wallet.md "Add-on passes").
//
// An add-on with its own entry code (DICE Extra.hasSeparateAccessBarcode, mig
// 20261107110000) gets one code per unit, scanned at the add-on's own list (a
// VIP lounge). Apple allows one barcode per pass (its `barcodes` array holds
// formats of the same message), so a code can't ride as a second barcode or a
// back field of the ticket's pass: each unit gets a pass of its own.
//   Apple   an eventTicket pass, static A-…:a{epoch}:… code, no web service
//           (getting it again gives the current state; the door refuses a
//           code once the pass is refunded or has a new holder, whatever the
//           phone still shows)
//   Google  an eventTicketObject with a rotating TOTP A-…:g{epoch}:… code,
//           stored server to server (the save JWT names only its id, so the
//           TOTP key is never in a URL), under the event's ticket class
// Pure; signing and fetch are injected (pkcs7.ts / google.ts).

import type { AppleIdentity } from "./apple.ts";
import { PASS_COLORS } from "./apple.ts";
import { type FetchLike, buildEventTicketClass, buildSaveUrl, googleAccessToken, googleRotatingBarcode, objectId, classId, type Rs256Signer, upsertResource } from "./google.ts";
import { localIso, type WalletPayload } from "./payload.ts";

export interface AddonWalletPayload {
  serial: string;
  pass_id: string;
  addon_name: string;
  unit_index: number;
  unit_count: number;
  status: "active" | "used" | "voided";
  code_epoch: number;
  updated_at: string;
  event: WalletPayload["event"];
  org_name: string | null;
  /** A-…:a{epoch}:… */
  apple_code: string | null;
  /** 20-byte TOTP key, hex. */
  google_key_hex: string | null;
  google_pattern: string;
}

const HOUR = 3600_000;

/** "VIP lounge" or "VIP lounge · 2 of 3". */
export function addonTitle(p: Pick<AddonWalletPayload, "addon_name" | "unit_index" | "unit_count">): string {
  return p.unit_count > 1 ? `${p.addon_name} · ${p.unit_index} of ${p.unit_count}` : p.addon_name;
}

/** Last 8 characters of the pass id, as shown under the code. */
export const shortPass = (id: string): string => id.replace(/-/g, "").slice(-8).toUpperCase();

/** pass.json of an add-on's Apple Wallet pass (no web service: static). */
export function buildAddonAppleJson(p: AddonWalletPayload, id: Omit<AppleIdentity, "webServiceURL">): Record<string, unknown> {
  const ev = p.event;
  const org = p.org_name || id.organizationName || "Exos";
  const secondary: Record<string, unknown>[] = [{ key: "event", label: "EVENT", value: ev.name }];
  if (ev.starts_at) {
    secondary.push({
      key: "starts", label: "DATE", value: localIso(ev.starts_at, ev.timezone),
      dateStyle: "PKDateStyleMedium", timeStyle: "PKDateStyleShort", ignoresTimeZone: true,
    });
  }
  const back: Record<string, unknown>[] = [
    { key: "pass", label: "Add-on", value: shortPass(p.pass_id) },
    {
      key: "about", label: "About this pass",
      value: "Show this code at the add-on's own entrance, not the main door: your ticket gets you in, this gets you the add-on. " +
        "A refunded or transferred add-on's code stops working at the door.",
    },
  ];
  if (ev.venue_location) back.push({ key: "address", label: "Address", value: ev.venue_location });
  const pass: Record<string, unknown> = {
    formatVersion: 1,
    passTypeIdentifier: id.passTypeIdentifier,
    teamIdentifier: id.teamIdentifier,
    serialNumber: p.serial,
    organizationName: org,
    description: `Add-on: ${p.addon_name} (${ev.name})`.slice(0, 120),
    logoText: org,
    ...PASS_COLORS,
    sharingProhibited: true,
    eventTicket: {
      headerFields: [{ key: "status", label: "STATUS", value: p.status === "used" ? "Used" : p.status === "voided" ? "Void" : "Valid" }],
      primaryFields: [{ key: "addon", label: "ADD-ON", value: addonTitle(p) }],
      secondaryFields: secondary,
      auxiliaryFields: ev.venue_name ? [{ key: "venue", label: "VENUE", value: ev.venue_name }] : [],
      backFields: back,
    },
  };
  if (ev.starts_at) {
    const start = new Date(ev.starts_at).getTime();
    const doors = ev.doors_at ? new Date(ev.doors_at).getTime() : start - 2 * HOUR;
    const end = ev.ends_at ? new Date(ev.ends_at).getTime() : start + 6 * HOUR;
    pass.relevantDate = localIso(new Date(Math.min(doors, start)).toISOString(), ev.timezone);
    pass.expirationDate = localIso(new Date(end + 12 * HOUR).toISOString(), ev.timezone);
  }
  if (p.status === "voided" || !p.apple_code) {
    pass.voided = true;
  } else {
    pass.barcodes = [{ format: "PKBarcodeFormatQR", message: p.apple_code, messageEncoding: "iso-8859-1", altText: shortPass(p.pass_id) }];
  }
  return pass;
}

/** The Google Wallet object of an add-on pass, under the event's ticket class. */
export function buildAddonGoogleObject(p: AddonWalletPayload, issuerId: string): Record<string, unknown> {
  const obj: Record<string, unknown> = {
    id: objectId(issuerId, p.serial),
    classId: classId(issuerId, p.event.id),
    state: p.status === "voided" ? "INACTIVE" : p.status === "used" ? "COMPLETED" : "ACTIVE",
    ticketNumber: shortPass(p.pass_id),
    ticketType: { defaultValue: { language: "en-US", value: addonTitle(p) } },
    hexBackgroundColor: "#111827",
    textModulesData: [{ id: "addon", header: "Add-on", body: "Show this code at the add-on's own entrance, not the main door." }],
  };
  if (p.status !== "voided" && p.google_key_hex) {
    obj.rotatingBarcode = googleRotatingBarcode(p.google_pattern, p.google_key_hex, shortPass(p.pass_id));
  }
  if (p.event.ends_at) {
    obj.validTimeInterval = { end: { date: localIso(new Date(new Date(p.event.ends_at).getTime() + 12 * HOUR).toISOString(), p.event.timezone) } };
  }
  return obj;
}

/** Store the event's class and the add-on's object, return the save link. */
export async function addonGoogleSaveLink(
  p: AddonWalletPayload,
  cfg: { issuerId: string; origins?: string[] },
  signer: Rs256Signer,
  fetchFn: FetchLike,
): Promise<string> {
  const token = await googleAccessToken(signer, fetchFn);
  await upsertResource(fetchFn, token, "eventTicketClass", buildEventTicketClass(p, cfg.issuerId));
  const obj = buildAddonGoogleObject(p, cfg.issuerId);
  await upsertResource(fetchFn, token, "eventTicketObject", obj);
  return buildSaveUrl(signer, [String(obj.id)], cfg.origins);
}
