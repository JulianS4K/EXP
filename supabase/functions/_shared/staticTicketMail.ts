// The PDF a ticket mail carries for static-code tickets (mig 20261121153000,
// docs/wallet.md "Static codes"). exos-mail-drain reads the rows from
// exos_mail_ticket_pdf_rows (service role: the codes are in that answer
// only), and this turns them into a Resend attachment plus one line for the
// mail body. Pure: Deno and vitest both load it.

import { staticTicketsPdf, type PrintTicket } from "./print/tickets.ts";
import { canonicalStaticCode } from "./staticCodes.ts";
import { toBase64 } from "./wallet/bytes.ts";

/** One ticket's PDF page (print_code carries the S- code). */
export type StaticPdfRow = PrintTicket;

/** At most this many tickets in one mail's PDF; the mail says where the rest are. */
export const MAX_PDF_TICKETS = 20;

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

export interface StaticAttachment {
  attachment: { filename: string; content: string };
  /** Appended to the mail's HTML. */
  note: string;
  /** Tickets on the PDF, and live ones left off it (past MAX_PDF_TICKETS: My Tickets has them). */
  attached: number;
  omitted: number;
}

/** The attachment and its note, or null when there is no live static ticket. */
export function staticTicketAttachment(rows: StaticPdfRow[]): StaticAttachment | null {
  const live = rows
    .filter((r) => r && typeof r.ticket_id === "string" && typeof r.event_name === "string")
    .map((r) => ({ ...r, print_code: canonicalStaticCode(r.print_code) ?? "" }))
    .filter((r) => r.print_code !== "" && r.print_code.slice(2, 38) === r.ticket_id.toLowerCase());
  if (live.length === 0) return null;
  const pages = live.slice(0, MAX_PDF_TICKETS);
  const n = pages.length;
  const rest = live.length - n;
  const title = pages[0].event_name;
  const pdf = staticTicketsPdf(pages, title);
  const what = rest > 0
    ? `The first ${n} of your ${live.length} tickets are attached as a PDF (${n} pages) for <strong>${esc(title)}</strong>; ` +
      "download the rest in My Tickets. "
    : `Your ticket${n > 1 ? "s are" : " is"} attached as a PDF${n > 1 ? ` (${n} pages)` : ""} for <strong>${esc(title)}</strong>. `;
  return {
    attachment: { filename: "tickets.pdf", content: toBase64(pdf) },
    note: `<p>${what}Print it or show it on your phone at the door. Each ticket lets one person in and the first scan wins, ` +
      "so don't share it.</p>",
    attached: n,
    omitted: rest,
  };
}
