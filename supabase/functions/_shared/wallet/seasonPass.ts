// Season-pass and flex-pack wallet cards (mig 20261102100000,
// exos_wallet_season_pass; docs/wallet.md): an Apple Wallet generic pass and
// a Google Wallet generic object showing the pass, the admissions left and
// what it covers.
//
// Not a door credential: a pass is used by redeeming it for tickets, and each
// ticket has its own rotating code. So the card has no barcode and holds
// nothing secret (no email, no price), which is why the Google card can go
// whole inside the save JWT (no REST call, no stored object), and the Apple
// card is static (no web service: getting it again gives the current
// numbers). Pure; signing is injected (pkcs7.ts / google.ts signers).

import { localIso } from "./payload.ts";
import type { AppleIdentity } from "./apple.ts";
import { PASS_COLORS } from "./apple.ts";
import { type Rs256Signer, signJwt } from "./google.ts";

export interface SeasonPassPayload {
  serial: string;
  pass_id: string;
  kind: "season" | "flex";
  name: string;
  org_name: string | null;
  credits_total: number | null;
  credits_used: number;
  per_event_limit: number | null;
  valid_until: string | null;
  date_from: string | null;
  date_to: string | null;
  events: { name: string; starts_at: string | null }[];
  updated_at: string;
}

const KIND_LABEL = { season: "Season pass", flex: "Flex pack" } as const;

/** Admissions left, or null for a season pass with no total (one per event). */
export function creditsLeft(p: SeasonPassPayload): number | null {
  return p.credits_total === null ? null : Math.max(0, p.credits_total - p.credits_used);
}

/** "Oct 2 – Dec 20, 2026" style range of a date-range season, in UTC (no event zone). */
export function seasonRange(from: string | null, to: string | null): string | null {
  const f = (iso: string) => new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  if (from && to) return `${f(from)} – ${f(to)}`;
  if (from) return `From ${f(from)}`;
  if (to) return `Until ${f(to)}`;
  return null;
}

/** What the pass covers, one line. */
export function coverage(p: SeasonPassPayload): string {
  if (p.events.length) {
    const names = p.events.slice(0, 3).map((e) => e.name).join(", ");
    return p.events.length > 3 ? `${names} and ${p.events.length - 3} more` : names;
  }
  return seasonRange(p.date_from, p.date_to) ?? "Any event of the organizer";
}

/** Short pass number shown on the card (not a code: nothing scans it). */
export const passNumber = (id: string): string => id.replace(/-/g, "").slice(-8).toUpperCase();

/** pass.json of the Apple Wallet card (generic style, no barcode, no web service). */
export function buildSeasonPassAppleJson(p: SeasonPassPayload, id: Omit<AppleIdentity, "webServiceURL">): Record<string, unknown> {
  const left = creditsLeft(p);
  const org = p.org_name || id.organizationName || "Exos";
  const secondary: Record<string, unknown>[] = [{ key: "covers", label: "COVERS", value: coverage(p) }];
  const auxiliary: Record<string, unknown>[] = [];
  if (p.per_event_limit) auxiliary.push({ key: "per-event", label: "PER EVENT", value: p.per_event_limit });
  if (p.valid_until) {
    auxiliary.push({ key: "valid", label: "VALID UNTIL", value: localIso(p.valid_until, null), dateStyle: "PKDateStyleMedium" });
  }
  const back: Record<string, unknown>[] = [
    { key: "number", label: "Pass", value: passNumber(p.pass_id) },
    {
      key: "about", label: "How to use it",
      value: "Use the pass in the Exos app to get tickets for an event it covers. Show those tickets at the door: " +
        "this card is not scanned. It shows the admissions left when you added it; add it again to refresh.",
    },
  ];
  if (p.events.length) back.unshift({ key: "events", label: "Events", value: p.events.map((e) => e.name).join("\n") });
  const pass: Record<string, unknown> = {
    formatVersion: 1,
    passTypeIdentifier: id.passTypeIdentifier,
    teamIdentifier: id.teamIdentifier,
    serialNumber: p.serial,
    organizationName: org,
    description: `${KIND_LABEL[p.kind]}: ${p.name}`.slice(0, 120),
    logoText: org,
    ...PASS_COLORS,
    sharingProhibited: true,
    generic: {
      headerFields: left === null ? [] : [{ key: "left", label: "LEFT", value: left }],
      primaryFields: [{ key: "name", label: KIND_LABEL[p.kind].toUpperCase(), value: p.name }],
      secondaryFields: secondary,
      auxiliaryFields: auxiliary,
      backFields: back,
    },
  };
  if (p.valid_until) pass.expirationDate = localIso(p.valid_until, null);
  return pass;
}

const ID_RE = /^[0-9]+$/;
const loc = (value: string) => ({ defaultValue: { language: "en-US", value } });

export function seasonPassClassId(issuerId: string): string {
  if (!ID_RE.test(issuerId)) throw new Error("issuer id must be numeric");
  return `${issuerId}.exos-season-pass`;
}

/** The Google Wallet generic class and object for a pass. */
export function buildSeasonPassGoogle(p: SeasonPassPayload, issuerId: string): { cls: Record<string, unknown>; obj: Record<string, unknown> } {
  const left = creditsLeft(p);
  const classId = seasonPassClassId(issuerId);
  const rows: { id: string; header: string; body: string }[] = [{ id: "covers", header: "Covers", body: coverage(p) }];
  if (p.per_event_limit) rows.push({ id: "per_event", header: "Per event", body: String(p.per_event_limit) });
  rows.push({ id: "how", header: "How to use it", body: "Get tickets with the pass in the Exos app and show those at the door. This card isn't scanned." });
  const obj: Record<string, unknown> = {
    id: `${issuerId}.exos-${p.serial}`,
    classId,
    state: "ACTIVE",
    cardTitle: loc((p.org_name || "Exos").slice(0, 60)),
    subheader: loc(KIND_LABEL[p.kind]),
    header: loc(p.name),
    hexBackgroundColor: "#111827",
    textModulesData: [
      ...(left === null ? [] : [{ id: "left", header: "Admissions left", body: String(left) }]),
      ...rows,
    ],
  };
  if (p.valid_until) obj.validTimeInterval = { end: { date: localIso(p.valid_until, null) } };
  return { cls: { id: classId }, obj };
}

/** A "Save to Google Wallet" URL carrying the whole card (nothing secret in it). */
export async function seasonPassSaveUrl(p: SeasonPassPayload, issuerId: string, signer: Rs256Signer, origins: string[] = [], iat?: number): Promise<string> {
  const { cls, obj } = buildSeasonPassGoogle(p, issuerId);
  const jwt = await signJwt({
    iss: signer.email, aud: "google", typ: "savetowallet", iat: iat ?? Math.floor(Date.now() / 1000), origins,
    payload: { genericClasses: [cls], genericObjects: [obj] },
  }, signer);
  return `https://pay.google.com/gp/v/save/${jwt}`;
}
