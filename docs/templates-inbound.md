# Templates, rental invoices and booking requests

Migration `20261102130000_exos_templates_inbound.sql`, harness
`tests/exos/test_templates_inbound.sql`, API `docs/api/templates.json`,
`rental-invoices.json`, `inbound-submissions.json`, `event-delete.json`.
Modelled on Opendate's admin template inventory and inbound submissions;
rental invoice numbering follows pretix's design (numbers given at issue,
never reused).

## Event templates

A saved event setup: name and description, capacity, doors and length
relative to the start, other event settings (`event_fields`, a fixed list of
event columns: `_exos_event_template_fields()`), ticket types with all-in
prices in cents, event fee rules, and whether the organization's fee rules
apply.

- **Create an event from one**: `exos_event_from_template(template, {name?,
  starts_at?, timezone?, exos_venue_id?, exos_room_id?})` or `POST
  /v1/event-templates/:id/events`. Always a **draft**; publish it as usual.
- **Save an event as one**: `exos_event_template_from_event(event, name)`,
  the event page's *Save as template*, or `POST /v1/event-templates` with
  `from_event_id`.
- Read: owner, manager, content, finance. Write: owner, manager.

## Note templates

Reusable booking-note bodies; applying one adds an `exos_event_notes` row
(*Add to show*, `POST /v1/note-templates/:id/apply`). Read: owner, manager,
content, finance. Write: owner, manager, content.

## Rental invoice templates and rental invoices

A template holds lines (`fixed` or `per_head`, quantity with 2 decimals,
cost in cents), deposits (flat or percent; due N days before the rental or
on a date), taxes / fees (a rate of the subtotal less the discount), payee,
notes and terms.

A rental invoice is made from a template (lines copied) or from scratch, for
a hold, one held night (venue, room and date come from the night) or a
venue / room on a date. Totals are computed by the database
(`_exos_rental_totals`; `src/lib/rentalInvoice.ts` mirrors it for the
editor).

| Status | Edit | Delete | Next |
|---|---|---|---|
| draft | yes | yes | issue |
| issued | no | no | paid, void |
| paid | no | no | issued (unmark), void |
| void | no | no | — |

**Numbering** (`exos_rental_invoice_counters`, one series per org, prefix
`R-` by default): a number is given only by `_exos_rental_invoice_issue`, in
the transaction that issues the invoice. It locks the org's counter row and
then the invoice (one lock order, so concurrent issues queue instead of
deadlocking); a failed issue rolls the counter back too. Issued invoices are
frozen by trigger and can never be deleted, and a void invoice keeps its
number, so the sequence has no gaps. Changing the prefix affects numbers not
yet given.

Read and write: owner, manager, finance (templates: owner, manager write).
API scopes: templates `booking:*`, invoices `finance:*`.

## Booking requests (inbound submissions)

An artist or agent asks to play. Two ways in:

- The org's **public form** at `/book/<org slug>`, off until an owner or
  manager switches it on (*Booking requests → Public form*). It calls the
  anon RPCs `exos_inbound_form_public` and `exos_inbound_submit`
  (`docs/security.md`, H3 allowlist). Protections: 16 KB body cap; unknown
  fields refused; https links only; a hidden `homepage` honeypot (answered
  `{ok: true}`, nothing stored); limits counted under advisory locks: per
  network 5 an hour per org and 20 a day overall (SHA-256 of the IP from
  `_exos_request_ip()`: `cf-connecting-ip`, else the last X-Forwarded-For
  entry, never the client-written first one; requests without a trusted IP
  share one `unknown` bucket with the same caps; the IP itself is never
  stored and the hash has no client column grant), per email 3 a day per org, 300
  a day per org.
- The API: `POST /v1/inbound-submissions` (`booking:write`), which accepts
  Opendate's `inbound_submission[...]` fields.

Staff review them (`new → reviewing → accepted / declined`, with a staff
note), turn one into a hold (`exos_inbound_create_hold`: marks it accepted
and links the hold; once only), or delete it. Review: owner, manager,
content. Holds, deletes and the form's settings: owner, manager.

## Deleting an event

`exos_event_delete(event)` / `DELETE /v1/events/:id`: only a draft (or
cancelled) event that never sold: no tickets, orders, invoices, payments,
refunds, disputes, reservations or recorded sales. Anything else answers
55000 / 409 "cancel it instead" (cancelling keeps the record and notifies
holders); a published event is unpublished first. Owner or manager (over
the API, the key's creator).
