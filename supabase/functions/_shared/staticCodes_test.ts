// Static door codes in the Deno runtime (mig 20261121153000): the PDF the
// confirmation email attaches (exos-mail-drain), and the wallet passes of a
// static-code ticket (exos-wallet). Run in CI's Deno line.
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { staticCode, staticCodeHash } from "./staticCodes.ts";
import { STATIC_FOOTER_LINES, staticTicketsPdf, type PrintTicket } from "./print/tickets.ts";
import { MAX_PDF_TICKETS, staticTicketAttachment } from "./staticTicketMail.ts";
import { fromBase64 } from "./wallet/bytes.ts";
import { buildApplePassJson } from "./wallet/apple.ts";
import { buildEventTicketObject } from "./wallet/google.ts";
import type { WalletPayload } from "./wallet/payload.ts";

const TICKET = "0b5e1c2a-0000-4000-8000-000000000001";
const OWNER = "0b5e1c2a-0000-4000-8000-0000000000c1";
const VECTOR = "S-0b5e1c2a-0000-4000-8000-000000000001:ZW5XLXNZPIYH54TJQQPNWMLXV37RBE2T";
const text = (b: Uint8Array) => Array.from(b, (c) => String.fromCharCode(c)).join("");

const row = (over: Partial<PrintTicket> = {}): PrintTicket => ({
  ticket_id: TICKET, print_code: VECTOR, event_name: "Basement Show", starts_at: "2026-12-05T01:00:00Z",
  timezone: "America/New_York", venue_name: "The Room", venue_location: "Brooklyn, NY", tier_name: "GA",
  attendee_name: "Sam Fan", org_name: "B5C Org", ...over,
});

Deno.test("static code: the Deno runtime derives the SQL vector", async () => {
  assertEquals(await staticCode(TICKET, OWNER, "sek-vector"), VECTOR);
  assertEquals(await staticCodeHash(VECTOR), "f4b68b536b94a59b7929f2022006fc21c2b018e7d8fcb75bfeca00a76d721e31");
});

Deno.test("PDF builder: one 4 x 8 in page per ticket, the code, the fields, the static small print", () => {
  const pdf = text(staticTicketsPdf([row(), row({ ticket_id: "t2", attendee_name: null })], "Basement Show"));
  assert(pdf.startsWith("%PDF-1.4\n"));
  assert(pdf.endsWith("%%EOF\n"));
  assertEquals((pdf.match(/\/Type \/Page /g) ?? []).length, 2);
  assertStringIncludes(pdf, "/MediaBox [0 0 288 576]");
  assertStringIncludes(pdf, `(${VECTOR.slice(0, 39)})`);
  assertStringIncludes(pdf, `(${VECTOR.slice(39)})`);
  assertStringIncludes(pdf, "(Basement Show)");
  assertStringIncludes(pdf, "(The Room, Brooklyn, NY)");
  assertStringIncludes(pdf, "(Admit: Sam Fan)");
  for (const l of STATIC_FOOTER_LINES) assertStringIncludes(pdf, `(${l})`);
  assert(!pdf.includes("Reprinting"), "the print code's small print stays off static tickets");
  // The QR is drawn as filled squares (no images, no fonts beyond Helvetica).
  assert((pdf.match(/ re\n/g) ?? []).length > 200);
  assert(!pdf.includes("/Image"));
  // The xref offsets point at the objects.
  const xref = Number(pdf.slice(pdf.lastIndexOf("startxref\n") + 10).split("\n")[0]);
  assertEquals(pdf.slice(xref, xref + 4), "xref");
});

Deno.test("mail attachment: base64 PDF of the live static rows, a note, nothing for none", () => {
  const a = staticTicketAttachment([row(), row({ ticket_id: "0b5e1c2a-0000-4000-8000-000000000009" })]);
  assert(a);
  assertEquals(a.attachment.filename, "tickets.pdf");
  const pdf = text(fromBase64(a.attachment.content));
  // The second row's code is for another ticket: dropped.
  assertEquals((pdf.match(/\/Type \/Page /g) ?? []).length, 1);
  assertStringIncludes(a.note, "attached as a PDF");
  assertStringIncludes(a.note, "first scan wins");
  assertEquals(staticTicketAttachment([]), null);
  assertEquals(staticTicketAttachment([row({ print_code: "T-x:y:1:z" })]), null);
  assertStringIncludes(a.note, "Your ticket is attached");
  assertEquals([a.attached, a.omitted], [1, 0]);
  // Escaped event name; capped page count, and the mail says where the rest are.
  const many = staticTicketAttachment(Array.from({ length: MAX_PDF_TICKETS + 5 }, () => row({ event_name: "<b>Show</b>" })));
  assertStringIncludes(many!.note, "&lt;b&gt;Show&lt;/b&gt;");
  assertEquals((text(fromBase64(many!.attachment.content)).match(/\/Type \/Page /g) ?? []).length, MAX_PDF_TICKETS);
  assertEquals([many!.attached, many!.omitted], [MAX_PDF_TICKETS, 5]);
  assertStringIncludes(many!.note, `The first ${MAX_PDF_TICKETS} of your ${MAX_PDF_TICKETS + 5} tickets`);
  assertStringIncludes(many!.note, "download the rest in My Tickets");
  assert(!many!.note.includes("Your tickets are attached"));
});

const payload = (over: Partial<WalletPayload> = {}): WalletPayload => ({
  serial: "exw0123456789abcdef0123456789abcdef", pass_type: "pass.com.exos.test", status: "active", void_reason: null,
  code_epoch: 1, updated_at: "2026-11-21T12:00:00Z",
  ticket: { id: TICKET, status: "active", tier_name: "GA", section_label: null, attendee_name: "Sam Fan", in_transfer: false, check_in_at: null },
  event: {
    id: "e1", name: "Basement Show", status: "published", starts_at: "2026-12-05T01:00:00Z", ends_at: null, doors_at: null,
    timezone: "America/New_York", venue_name: "The Room", venue_location: "Brooklyn, NY", lat: null, lng: null,
  },
  org_name: "B5C Org",
  apple_code: `W-${TICKET}:${OWNER}:a1:abc`,
  google_key_hex: "133015cacf7d7a699286a00f41c09045724e85df",
  google_pattern: `W-${TICKET}:${OWNER}:g1:{totp_value_0}`,
  ...over,
});
const ID = { passTypeIdentifier: "pass.com.exos.test", teamIdentifier: "ABCDE12345", webServiceURL: "https://x.test/apple" };

Deno.test("wallet: a static ticket's passes carry its S- code; a rotating one's keep W- / TOTP", () => {
  // deno-lint-ignore no-explicit-any
  const apple: any = buildApplePassJson(payload({ static_code: VECTOR }), ID, "tok_".padEnd(43, "x"));
  assertEquals(apple.barcodes[0].message, VECTOR);
  assertEquals(apple.barcodes[0].format, "PKBarcodeFormatQR");
  // deno-lint-ignore no-explicit-any
  const google: any = buildEventTicketObject(payload({ static_code: VECTOR }), "3388000000000000000");
  assertEquals(google.barcode, { type: "QR_CODE", renderEncoding: "UTF_8", value: VECTOR, alternateText: "00000001" });
  assertEquals(google.rotatingBarcode, undefined);

  // deno-lint-ignore no-explicit-any
  const appleRot: any = buildApplePassJson(payload(), ID, "tok_".padEnd(43, "x"));
  assertEquals(appleRot.barcodes[0].message, `W-${TICKET}:${OWNER}:a1:abc`);
  // deno-lint-ignore no-explicit-any
  const googleRot: any = buildEventTicketObject(payload({ static_code: null }), "3388000000000000000");
  assert(googleRot.rotatingBarcode && !googleRot.barcode);
  // A voided pass shows no code at all.
  // deno-lint-ignore no-explicit-any
  const voided: any = buildApplePassJson(payload({ static_code: VECTOR, status: "voided", apple_code: null }), ID, "tok_".padEnd(43, "x"));
  assertEquals(voided.barcodes, undefined);
  // Anything that isn't an S- code is ignored.
  // deno-lint-ignore no-explicit-any
  const odd: any = buildApplePassJson(payload({ static_code: "T-forged" }), ID, "tok_".padEnd(43, "x"));
  assertEquals(odd.barcodes[0].message, `W-${TICKET}:${OWNER}:a1:abc`);
});
