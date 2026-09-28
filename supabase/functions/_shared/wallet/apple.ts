// Apple Wallet (.pkpass) builder: pass.json, manifest.json (SHA-1 of every
// file), the detached PKCS#7 "signature", zipped. Pure; signing is injected.
//
// Apple passes can't run a rotating code, so pass.json carries the pass's W-
// code (codes.ts) and a webServiceURL + authenticationToken: when the ticket
// changes (checked in, transferred, voided, reissued) exos-wallet pushes and
// the device fetches the new pass (voided: true after a transfer / refund).
// Security trade-off: docs/wallet.md.

import { toHex, sha1, utf8 } from "./bytes.ts";
import type { PassSigner } from "./pkcs7.ts";
import { displayState, localIso, shortTicket, VOID_TEXT, type WalletPayload } from "./payload.ts";
import { solidPng } from "./png.ts";
import { zipStore } from "./zip.ts";

export interface AppleIdentity {
  passTypeIdentifier: string;
  teamIdentifier: string;
  /** Base URL Apple appends /v1/... to (must be https). */
  webServiceURL: string;
  organizationName?: string;
}

export const PASS_COLORS = {
  backgroundColor: "rgb(17, 24, 39)",
  foregroundColor: "rgb(255, 255, 255)",
  labelColor: "rgb(156, 163, 175)",
};

type Field = Record<string, unknown> & { key: string; value: string | number };

const HOUR = 3600_000;

export function buildApplePassJson(
  p: WalletPayload,
  id: AppleIdentity,
  authenticationToken: string,
): Record<string, unknown> {
  const state = displayState(p);
  const ev = p.event;
  const tz = ev.timezone;
  const startIso = ev.starts_at ?? null;

  const primaryFields: Field[] = [{ key: "event", label: "EVENT", value: ev.name }];
  const secondaryFields: Field[] = [];
  if (startIso) {
    secondaryFields.push({
      key: "starts", label: "DATE", value: localIso(startIso, tz),
      dateStyle: "PKDateStyleMedium", timeStyle: "PKDateStyleShort", ignoresTimeZone: true,
    });
  }
  if (ev.venue_name) secondaryFields.push({ key: "venue", label: "VENUE", value: ev.venue_name });

  const auxiliaryFields: Field[] = [];
  const tier = [p.ticket.tier_name, p.ticket.section_label].filter(Boolean).join(" · ");
  if (tier) auxiliaryFields.push({ key: "tier", label: "TICKET", value: tier });
  if (p.ticket.attendee_name) auxiliaryFields.push({ key: "holder", label: "NAME", value: p.ticket.attendee_name });
  if (ev.doors_at) {
    auxiliaryFields.push({
      key: "doors", label: "DOORS", value: localIso(ev.doors_at, tz),
      timeStyle: "PKDateStyleShort", ignoresTimeZone: true,
    });
  }

  const statusText: Record<string, string> = {
    "valid": "Valid",
    "checked-in": "Checked in",
    "in-transfer": "Transfer pending",
    "void": "Void",
  };
  const headerFields: Field[] = [{
    key: "status", label: "STATUS", value: statusText[state],
    changeMessage: "Your ticket is now: %@",
  }];

  const backFields: Field[] = [
    { key: "ticket", label: "Ticket", value: shortTicket(p.ticket.id) },
  ];
  if (ev.venue_location) backFields.push({ key: "address", label: "Address", value: ev.venue_location });
  if (state === "void") {
    backFields.unshift({
      key: "void", label: "Void",
      value: VOID_TEXT[p.void_reason ?? ""] ?? VOID_TEXT["ticket-voided"],
    });
  }
  backFields.push({
    key: "about", label: "About this pass",
    value: "The code updates when your ticket changes. Transfers and refunds are handled in the Exos app; " +
      "a transferred or refunded ticket's pass stops working at the door.",
  });

  const pass: Record<string, unknown> = {
    formatVersion: 1,
    passTypeIdentifier: id.passTypeIdentifier,
    teamIdentifier: id.teamIdentifier,
    serialNumber: p.serial,
    authenticationToken,
    webServiceURL: id.webServiceURL,
    organizationName: p.org_name || id.organizationName || "Exos",
    description: `Ticket: ${ev.name}`.slice(0, 120),
    logoText: p.org_name || id.organizationName || "Exos",
    ...PASS_COLORS,
    sharingProhibited: true,
    eventTicket: { headerFields, primaryFields, secondaryFields, auxiliaryFields, backFields },
  };

  if (startIso) {
    const start = new Date(startIso).getTime();
    const doors = ev.doors_at ? new Date(ev.doors_at).getTime() : start - 2 * HOUR;
    const end = ev.ends_at ? new Date(ev.ends_at).getTime() : start + 6 * HOUR;
    pass.relevantDate = localIso(new Date(Math.min(doors, start)).toISOString(), tz);
    // iOS 18+: a window instead of one instant.
    pass.relevantDates = [{
      startDate: localIso(new Date(Math.min(doors, start) - HOUR).toISOString(), tz),
      endDate: localIso(new Date(end).toISOString(), tz),
    }];
    pass.expirationDate = localIso(new Date(end + 12 * HOUR).toISOString(), tz);
  }
  if (typeof ev.lat === "number" && typeof ev.lng === "number") {
    pass.locations = [{ latitude: ev.lat, longitude: ev.lng, relevantText: `${ev.name}: show your ticket at the door` }];
  }

  if (state === "void") {
    pass.voided = true;
  } else if (p.apple_code) {
    pass.barcodes = [{
      format: "PKBarcodeFormatQR",
      message: p.apple_code,
      messageEncoding: "iso-8859-1",
      altText: shortTicket(p.ticket.id),
    }];
  }
  return pass;
}

/** manifest.json: file name → SHA-1 hex of its bytes. */
export async function buildManifest(files: Record<string, Uint8Array>): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  for (const name of Object.keys(files).sort()) out[name] = toHex(await sha1(files[name]));
  return out;
}

/** Default images (Apple requires icon.png; logo is optional but expected). */
export function defaultPassImages(): Record<string, Uint8Array> {
  const bg = "#111827";
  const accent = "#6366f1";
  return {
    "icon.png": solidPng(29, 29, accent),
    "icon@2x.png": solidPng(58, 58, accent),
    "icon@3x.png": solidPng(87, 87, accent),
    "logo.png": solidPng(50, 50, bg),
    "logo@2x.png": solidPng(100, 100, bg),
  };
}

export interface Pkpass {
  bytes: Uint8Array;
  files: Record<string, Uint8Array>;
  manifest: Record<string, string>;
}

/** pass.json + images → manifest → signature → zip. The signer is injected. */
export async function buildPkpass(
  passJson: Record<string, unknown>,
  signer: PassSigner,
  images: Record<string, Uint8Array> = defaultPassImages(),
  at: Date = new Date(),
): Promise<Pkpass> {
  const files: Record<string, Uint8Array> = { "pass.json": utf8(JSON.stringify(passJson)), ...images };
  const manifest = await buildManifest(files);
  const manifestBytes = utf8(JSON.stringify(manifest));
  const signature = await signer.sign(manifestBytes);
  const all: Record<string, Uint8Array> = { ...files, "manifest.json": manifestBytes, signature };
  const bytes = zipStore(Object.keys(all).map((name) => ({ name, data: all[name] })), at);
  return { bytes, files: all, manifest };
}

export const PKPASS_MIME = "application/vnd.apple.pkpass";
