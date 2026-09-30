# Exos email

Every mail Exos sends goes through one queue, `public.exos_mail`, and one sender, the `exos-mail-drain` edge
function (Resend). Nothing sends mail directly.

- **Queue:** SQL functions and triggers insert rows. Clients can't: the table is service-role only and the few
  client RPCs (`exos_queue_mail`, `exos_notify_event_holders`, ...) derive the recipient server-side.
- **Two kinds of row.**
  - *html rows* (the older templates): the body is rendered in SQL when queued. Links carry the literal
    `{{app_url}}`, which the drain fills from `EXOS_APP_URL` (`_shared/mail-render.ts`).
  - *payload rows* (migration `20260929071000_exos_mail_templates`): `exos_mail_enqueue()` stores a small JSON
    `payload` and an empty `html`. The drain renders subject + body with `_shared/mail-templates.ts`, which escapes
    every value and only builds links from the app URL plus UUIDs. Tests: `src/lib/mailTemplates.test.ts`.
- **Sender:** `exos-mail-drain` claims a batch (`exos_mail_claim_batch`, `FOR UPDATE SKIP LOCKED`), renders, sends,
  and marks each row sent / retry / failed (`exos_mail_mark`). A row that won't render (no `EXOS_APP_URL`, unknown
  template, bad payload) is retried like a provider error and fails at the attempt cap.

## Rules

- **Transactional mail always sends.** Receipts, tickets, transfers, refunds, event changes, payouts, fee notices,
  organizer alerts.
- **Follow-ups ("marketing-ish") respect the opt-out.** They need an Exos account (the opt-out lives on it:
  `exos_mail_prefs.marketing_opt_out`), carry an unsubscribe link in the footer and a `List-Unsubscribe` header,
  and are skipped for anyone who opted out. `/unsubscribe?t=<token>` (signed out) and `exos_set_marketing_emails`
  (signed in) set it. One switch covers every follow-up.
- **Never twice.** Every follow-up and alert has a dedupe key (`template:thing:recipient-id`) claimed in
  `exos_mail_dedupe` before it's queued (primary key, `ON CONFLICT DO NOTHING`). Keys hold ids only, no email
  addresses, and the ledger outlives `exos_mail` purges. A retried trigger, a re-run cron or two overlapping runs
  queue nothing new.
- **No buyer PII in organizer mail.** Organizer mails carry counts, amounts and event facts. No buyer names, emails
  or order references (the SQL test checks this). Dispute mails follow it too: they link to the event's Money
  section, where the order is listed for staff who may see it.
- **Organizer text is escaped.** Event names, venues, org names and cancel reasons are stored raw in the payload
  and escaped by the renderer. Subjects are plain text with line breaks stripped.
- **All-in prices.** Buyer mail shows what the buyer paid, tax included, and says no fees were added.

## Templates

Audience: **B** buyer / ticket holder, **O** organizer (owner + active managers unless noted). Kind: **T**
transactional, **M** follow-up (opt-out). Render: **SQL** (html row) or **TS** (payload row).

### Buyer

| Template | Trigger | Kind | Dedupe | Render |
|---|---|---|---|---|
| `ticket-issued` | Paid order fulfilled into a wallet (`exos_fulfill_checkout`), comps (`exos_issue_comp_batch`) | T | once per session (fulfilment is idempotent) | SQL; a paid order appends the receipt (`exos_receipt_html`): amount, tax, line items, "all-in, no fees added", tickets link |
| `transfer-initiated` | Guest order with no account yet (claim link per ticket + receipt), ticket transfer, email comp, marketplace order, resend of marketplace claim links | T | per call (resend: once per 10 min) | SQL |
| `transfer-claimed`, `transfer-sent` | Transfer claimed / sent (sender's copy) | T | per transfer | SQL |
| `order-failed` | Paid but the seats were gone at fulfilment; refund starts | T | per session | SQL |
| `event-reminder` | Cron `exos_send_event_reminders`: T-24h and T-2h; staff "send reminder now" (6h cooldown) | T | stamps on the event row | SQL; tickets link. A ticket parked on the org owner for a pending claim doesn't remind the owner |
| `event-updated` | Organizer clicks "notify attendees" (`exos_notify_event_holders`) | T | none: an explicit action | TS: current time, doors, venue, event link |
| `event-rescheduled` | `exos_reschedule_event` (mig 20260929150000; also the Edit event save when the date change qualifies) | T | per reschedule + address | TS: old and new date / time and doors in the event's zone, the organizer's note. When refunds are offered: a link per ticket the address may act on, until the deadline: **Get a refund** (tickets they paid for through Exos, amount incl. tax) or **Release my ticket** (free / comp they hold), `/refund?t=<64-hex token>`, one token per ticket + reschedule. Marketplace tickets: "refunds go through the marketplace". A holder someone else paid for: "only they can ask". Not offered: "nothing you need to do" |
| `event-cancelled` | Event status → `cancelled` (trigger; any path) and the SPA's follow-up call | T | per event + address | TS: reason, and each holder's refund status: refunded / partial / processing / pending / free / someone else paid |
| `refund-issued` | A refund row reaches `succeeded` (`exos_order_refunds` trigger; Stripe webhook, organizer refunds, auto-refunds) | T | per refund row | TS: amount, progress for a partial refund, order reference |
| `waitlist-open` | Waitlist offer (code + hours to use it) | T | per offer | SQL |
| `event-announcement` | Organizer announcement to holders | T | per announcement | SQL |
| `checkout-abandoned` | Cron `exos_send_checkout_reminders`: checkout expired 1-24h ago, seats left | M | per buyer + event, forever | SQL |
| `post-event` | Cron `exos_send_mail_followups`: event ended 12h-3d ago | M | per event + holder | TS: thanks, "follow <org>" (unless following), up to 3 next events |

`event-rescheduled` recipients: the holder of every ticket (a ticket parked for a pending claim goes to the person
it's waiting for, never to the org owner) plus, when refunds are offered, the payer of every refundable ticket (the
checkout's buyer email), so a buyer who gave a ticket away still gets its refund link. One mail per address; at most
40 links of each kind (the rest are on My Tickets). The tokens live in `exos_reschedule_links` (service role only)
and only ever act on their own ticket, their own action and the event's latest reschedule. Rows queued before
mig 20260929150000 were SQL-rendered html rows and still send as they are.

`post-event` goes to holders with an account, not to org staff, not for tickets still waiting to be claimed, and
not when the org turned it off (`exos_orgs.post_event_emails_enabled`, default on).

### Organizer

| Template | Trigger | Audience | Kind | Dedupe | Render |
|---|---|---|---|---|---|
| `event-published` | Event status → `published` (trigger); first date of a series only | O | T | per event + person | TS |
| `inventory-low` | Cron: a tier on a published, upcoming event has ≤ 10% (min 1) left | O | T | per tier + capacity + person | TS |
| `inventory-sold-out` | Cron: a tier has none left | O | T | per tier + capacity + person (raising capacity re-arms it) | TS |
| `marketplace-attention` | A marketplace order needs a person | O | T | per order + reason | SQL |
| `payout-sent`, `payout-pending` | `exos_queue_payout_mail(org, amount_cents, currency, period, status, reference)`, for the payout ledger to call | O + finance | T | per org + status + reference (or period) + person | TS |
| `fee-free-ending` | Cron: 14 days and 1 day before `exos_org_billing.fee_free_until` | O + finance | T | per org + end date + stage + person | TS |
| `dispute-opened` | `stripe-webhook` → `exos_record_dispute_event` (mig 20261001101000): a chargeback or inquiry opened | owner + finance | T | per dispute + person (`dispute-opened:<dispute id>:<user>`), whatever Stripe sends after | TS: amount, reason in words, the Stripe fee, evidence deadline and what to send; links to the event's Money section and (for Exos staff) the dispute in the Stripe dashboard, the one link outside the app, built from a checked `dp_` / `du_` id |
| `dispute-won`, `dispute-lost` | The dispute closed won / lost | owner + finance | T | per dispute + person | TS: lost says the order's tickets are void and, per `exos_org_billing.recover_lost_disputes`, either that nothing is taken from payouts or the amount + fee that can be (`docs/payouts.md`) |
| `org-welcome` | Cron: org created < 2 days ago | owner | T | per org | TS |
| `org-first-event` | Cron: day 3-7, only while the org has no event | owner | M | per org | TS |
| `org-connect-stripe` | Cron: day 7-14, only while Stripe can't take payments (`exos_org_secrets.payments.chargesEnabled`) | owner | M | per org | TS |
| `org-sales-digest` | Cron: yesterday (UTC), only orgs that sold something | O | M | per org + day + person | TS: per-event tickets and gross, totals per currency |
| `org-weekly-summary` | Cron: last Monday-Sunday (UTC); orgs with sales that week or an event in the next 14 days | O | M | per org + week + person | TS: sales, check-ins, next two weeks' events with sold / capacity |
| `org-invite`, `invite-accepted` | Member invites | invitee / inviter | T | per invite | SQL |

Onboarding stops when done: the day-3 nudge is skipped once the org has an event, the day-7 nudge once Stripe is
connected. Windows are bounded, so the first run after deploy doesn't mail orgs about their distant past.

## Scheduling

`exos_send_mail_followups()` (service role, `cron_should_fire` gated, 20 s budget) queues every scheduled
follow-up: post-event, onboarding, fee-free notices, inventory alerts, the daily digest and the weekly summary. It
returns one row per template with the count queued (plus `failed` when some raised; they're logged as warnings and
retried next run). Hourly is plenty; every mail is once-only, so running it more often only makes alerts faster.

**The migration schedules nothing.** Cron changes are operator-gated. The line to add:

```sql
select cron.schedule('exos_send_mail_followups', '23 * * * *',
  $cron$SELECT * FROM public.exos_send_mail_followups();$cron$);
```

The other mail crons already exist: `exos-mail-drain-2min` (the sender), `exos_send_event_reminders` (every
15 min) and `exos_send_checkout_reminders` (hourly at :17).

## Going live (operator)

1. Apply `20260929071000_exos_mail_templates` (operator-gated). Safe before or after step 2: an old drain never
   claims payload rows (`p_render_payload` defaults to false), so they wait for the new one.
2. Deploy `exos-mail-drain`. `EXOS_APP_URL` must be set: every payload mail links into the app, and rows are held
   back (retried) without it.
3. Add the cron line above.
4. The payout ledger calls `exos_queue_payout_mail` when it records a payout.

## Adding a template

1. Add the name to the `exos_mail_template_check` allowlist with the union `DO` block (copy it from the latest
   migration that touches it; never rebuild the list from scratch, it has dropped live values before).
2. Queue it with `exos_mail_enqueue(template, to, payload, dedupe_key, user_id, marketing, created_by)`.
3. Add a renderer to `RENDERERS` in `_shared/mail-templates.ts` and a payload to `PAYLOADS` in
   `src/lib/mailTemplates.test.ts` (the test fails until both exist).
4. SQL test in `tests/exos/`, wired into `run_p0.sh`.
