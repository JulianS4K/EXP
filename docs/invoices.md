# Invoices, receipts and credit notes

Every paid Exos checkout gets an invoice with a per-organizer number. Buyers see it as a **receipt**; a
refund, full or partial, gets a **credit note** with its own number. Invoices never change after they're
issued.

- **Migrations:** `20260616240000_exos_invoicing.sql` (invoices, numbering) and
  `20261001100000_exos_invoices_credit_notes.sql` (credit notes, legal details, the document RPCs; **not
  applied** to prod yet).
- **Tests:** `tests/exos/test_invoices_credit_notes.sql` (in `run_p0.sh`), `src/lib/invoices.test.ts`, and the
  smoke test "receipt page".
- **Code:** `src/lib/invoices.ts` (pure: tax lines, totals, formatting), `src/lib/invoicesApi.ts` (reads),
  `src/views/InvoiceView.tsx` (the printable page), `src/components/OrgLegalSettings.tsx` (settings).

## Numbering

| Series | Format | Counter | Issued when |
|---|---|---|---|
| Invoice | `INV-000001` | `exos_invoice_counters`, one per org | the checkout session becomes `fulfilled` with an amount above 0 (trigger `exos_checkout_invoice`) |
| Credit note | `CN-000001` | `exos_credit_note_counters`, one per org | an `exos_order_refunds` row becomes `succeeded` on an invoiced order (trigger `exos_order_refunds_credit_note`) |

Both series are gapless: the counter row is incremented in the same transaction as the insert, so a failure
rolls both back. There's no Postgres sequence (sequences skip numbers on rollback). An order fulfilled a second
time doesn't take a new number. Each org has its own series, starting at 1.

## What's on an invoice

`exos_invoices` stores a snapshot at issue: number, date, currency, subtotal, tax and total (the checkout
amount, tax included), the buyer's email, and `seller` (the org name and legal details as they were then). The
number, amounts, currency, date and seller can't be changed afterwards (trigger `exos_invoices_frozen`); only the
buyer email can be cleared (account deletion) and the status set to `cancelled`.

The printable page reads the rest through `exos_invoice_document(invoice_id)`:

- **Seller:** legal name (else the org name), address, tax ID and the receipt footer, from the snapshot, or the
  org's current details for invoices issued before the snapshot existed.
- **Buyer:** display name (when the account has one) and email.
- **Lines:** what the buyer was shown at checkout (`exos_price_disclosure_lines`): each ticket type and add-on
  with quantity, all-in unit price and line total, and the tax in it with the tax rule's name and rate. Orders
  from before the price-disclosure record show the ticket type from the order and its add-ons, with the
  invoice's total tax on one line.
- **Tax per rate**, the total paid, every credit note with its number, and the balance after refunds.

Prices are all-in (tax included, no fees), so the lines add up to the total and the tax lines say how much of it
was tax.

## Credit notes

One credit note per succeeded refund row (`refund_id` is unique), linked to the invoice and the refund:

- **Amount:** the refund's amount, capped at what's left on the invoice. Once the invoice is fully credited,
  further refunds get no note.
- **Tax share:** pro rata, `round(invoice tax × amount / invoice total)`; the note that brings the total credited
  to the invoice total takes the remaining tax, so the notes' tax always adds up to the invoice's.
- A pending or failed refund gets no note; a refund that goes failed → succeeded again reuses its note. A refund
  on a free order (no invoice) gets none.
- Credit notes can't be changed. A problem issuing one is logged as a warning and never blocks recording the
  refund.
- The migration backfills notes for refunds that had already succeeded on invoiced orders.

### Status

The invoice's own `status` stays `issued` (rows flipped to `refunded` before this migration stay as they were).
`exos_invoice_totals` (a `security_invoker` view) adds `refunded_cents`, `refunded_tax_cents`, `net_cents`,
`credit_notes` and a derived `status`: `issued`, `partially_refunded`, `refunded` or `cancelled`. The public API
(`exos-api` `GET /invoices`) reads it.

## Free orders

A free order (amount 0) gets no invoice from this migration on. `$0` invoices issued before stay. Free claims and
comps still have no order row of their own (money audit #11).

## Who sees what

| Who | Sees |
|---|---|
| Buyer | **My Tickets → Receipts → Receipt** per order (`exos_my_invoices`). The page `/invoice/:id` and the credit notes linked from it (`/credit-note/:id`). A guest checkout's receipts show up once the buyer signs in with a confirmed account on the order's email |
| Owner / manager / finance | Event report → Overview → **Money** → **Receipts** (one row per order with its invoice number, total and refunded amount, linking to the page). The **Orders CSV** has an `invoice_number` column. Settings → **Legal & invoices** |
| Scanner, content, anyone else, anon | Nothing: the RPCs answer "not found" and RLS returns no rows |

The page has a **Print / save as PDF** button (`window.print()`); the print styles drop the buttons and the
background, and the browser suggests `receipt-INV-000001` as the file name.

## Seller legal details

Settings → **Legal & invoices** (`exos_org_legal`, one row per org): legal name (200 characters), address (500),
tax ID (64) and receipt footer (500). Owner, manager and finance read and write it; it isn't a column of
`exos_orgs`, so it never reaches `exos_public_orgs` or anyone else in the org. A change applies to invoices and
credit notes issued afterwards; earlier ones keep their snapshot.

## Not built

- Business invoices with the buyer's company and tax ID (everything is a consumer receipt today).
- Emailing the receipt as a PDF (the order email already carries the line items, `exos_receipt_html`).
- Invoices for marketplace orders (the marketplace invoices its buyer) and for POS sales.
- Invoice language / localisation, and per-country numbering rules.
