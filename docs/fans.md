# Fans, signup forms, tags and refund requests

Migration `20261031120000_exos_fans.sql`, harness `tests/exos/test_fans.sql`. Dashboard: `/orgs/:orgId/fans`
(`src/views/OrgFans.tsx`, linked as **Fans** on the dashboard). Partner API: `/v1/fans`, `/v1/tags`,
`/v1/tagged-items`, `/v1/canonical-tags`, `/v1/refund-requests` (`docs/api/fans.json`, `tags.json`,
`orders.json`).

## Fan profiles

One row per organization and email in `exos_fans`: the person behind the org's orders and signups.

- **Built automatically.** A checkout that becomes fulfilled (trigger on `exos_checkout_sessions`, which never
  fails the order) and a signup-form submission each make or refresh the profile. The migration backfills
  profiles from existing orders. Staff can add a contact by hand (email, first and last name) and remove one
  (soft delete: hidden, names cleared, tags off; orders stay; a new order or signup brings the profile back).
- **Minimal personal data.** Email, an optional first and last name, the link to an Exos account. No phone,
  address or birthday on the profile. Money is computed from the payment ledger when a profile is opened.
- **Consent is read-only for staff.** The profile shows each consent state: the org's email list (subscribed /
  pending / unsubscribed / none), whether the fan follows the org, their latest advertising choice at
  checkout, the platform-wide marketing opt-out, and texts (with a masked number). Nothing in the dashboard or
  the API changes one. The email-list columns change only inside the fan's own actions
  (`exos_signup_confirm`, `exos_signup_unsubscribe`); the `exos_fans_consent_guard` trigger refuses every
  other write to them, the service role and scripts included.
- **Who sees what.** Owner / manager / finance read fans; owner / manager add, rename, remove and export them.

### Export

**Export CSV** on the Fans tab (owner / manager only). `exos_org_fans_export` logs who exported what (filters,
row count) in `exos_fan_exports`, allows 3 a minute and 20 a day per org, and returns email, names, account
yes / no, source, order counts and dates, email-list state, tag names and the date added. The CSV is built in
the browser (`fansCsvRows` + `src/lib/csv.ts`, which defuses formula-looking text). No unsubscribe tokens, no
phone numbers.

## Followers

Mig `20261111110000_exos_neighborhoods.sql`, harness `tests/exos/test_neighborhoods.sql` (race:
`tests/exos/race_follower_mail.sh`, by hand). Fans follow an organizer from its page (`exos_follow_org`, mig
20260520140000).

- **The "new event" email.** When an event goes live and listed (published, not hidden from search, starting in the
  future; a series announces its first date only), every follower gets one notice row (`exos_follower_notices`,
  keyed by event and follower, so republishing, un-hiding or `exos_announce_to_followers` never sends twice). It
  becomes the `follower-new-event` mail (`docs/email.md`) only for a follower who may get marketing mail:
  - still following, and not on the org's team;
  - an account with an email;
  - not opted out of Exos follow-up mail (`exos_mail_prefs.marketing_opt_out`, the `/unsubscribe` link);
  - not unsubscribed from this org's email list (`exos_fans`).
- **At most one a day.** One mail per follower per org per 24 hours (`exos_follower_mail_slots`). An event published
  inside the window waits and goes out with the next mail, batched with whatever else is waiting (up to 10 events
  listed, "and N more"): with the org's next publish after the window, or from `exos_send_follower_digests` (cron
  `exos-follower-digests-hourly`, created inactive; turn it on with the mail drain).
- **Leaving.** Each mail carries a one-click unfollow for that org (`/unfollow?t=<64 hex>`, `exos_unfollow_by_token`;
  the page takes a click so mail scanners don't unfollow anyone) and the usual unsubscribe footer and
  `List-Unsubscribe` header for every follow-up.
- **Nothing sends yet.** Rows wait in `exos_mail` like every other mail until `exos-mail-drain` runs with Resend.
- **What the organizer sees.** Counts only, on the event editor (`exos_event_follower_notice`, owner / manager):
  "N followers will be notified when you publish", then "Notified N followers" (and how many are waiting for their
  daily window); the publish toast says it too. Nobody's address.
- **Follower list.** The **Followers** tab on the Fans page (owner / manager): how many follow, how many get the
  email, and rows (email, names, since when, email-list state, gets the email) only for followers who already have a
  fan profile with the org, which the Fans tab shows anyway. The rest are a count: following alone never hands the
  organizer an address. **Export CSV** (`exos_org_followers_export`) returns the same rows, allows 3 a minute and 20 a
  day per org, and writes an `export.run` row (entity `followers`) to the org audit log.

## Signup forms

An org builds a form (title, intro, button, whether to ask for a name, whether to offer texts, tags to put on
new signups) on the **Signup forms** tab and pastes the snippet on its site:

```html
<div data-exos-signup="FORM_ID"></div>
<script src="https://<exos host>/bridge/embed.js" async></script>
```

`public/embed.js` turns it into an iframe of `/embed/signup/:formId` (`src/views/EmbedSignup.tsx`) that sizes
itself. A plain `<iframe>` version and a direct link are offered too. The page has no payment field.

- **Endpoint.** The form posts to the `exos-signup` edge function: `POST /exos-signup/<form id>`,
  `POST /exos-signup/forms/<form id>/submissions` (Opendate's embed path) or `POST /exos-signup` with
  `form_id`. JSON or form-encoded, 16 KB cap. CORS-open (any site can host a form). Deploy it with
  `--no-verify-jwt` if sites post to it directly; the embed sends the anon key anyway.
- **Never returns fan data.** Every accepted submission answers `{ "ok": true, "status": "check_email" }`,
  whether the address is new, already subscribed or held back by a limit.
- **Limits.** 10 submissions a minute per network (hashed IP, never stored raw) and 120 a minute per form
  (`exos_rate_hit`; limiter down = 503); in SQL, 20 an hour per network per org and 3 a day per address per
  org. A hidden honeypot field (`url`): a filled one is answered as usual and nothing is saved.
- **Captcha hook.** Off by default. Set `EXOS_SIGNUP_CAPTCHA_SECRET` (and `EXOS_SIGNUP_CAPTCHA_PROVIDER` =
  `turnstile`, the default, or `hcaptcha`) on the function and `VITE_EXOS_CAPTCHA_SITE_KEY` in the SPA build:
  the embed then shows a Turnstile widget and the function verifies its token before anything is written.
- **Email is double opt-in.** The submission queues the `signup-confirm` mail (`docs/email.md`) with a link to
  `/signup/confirm?t=<64-hex token>`; only the token's hash is stored and it lasts 7 days. The page takes a
  click (a mail scanner opening the link confirms nothing). Only then is the fan on the list.
- **Texts follow the existing compliant flow.** The form shows the same consent words as the ticket page
  (`consentText` in `src/lib/sms.ts`; the SQL builds the identical text in `exos_sms_consent_text`, and
  `src/lib/signupForms.test.ts` checks they match) and stores them with the number. The number joins
  `exos_sms_subscribers` only when the fan, **signed in**, presses **Turn on texts** on the confirm page
  (`exos_signup_confirm_sms`): the same "signed in only, so a stranger can't sign someone else's number up"
  rule as `exos_sms_opt_in`. Unconfirmed numbers are cleared after 30 days (`exos_signup_sweep`, service role;
  add it to a daily cron). STOP handling and the 30-day cap are the SMS feature's own.
- **Leaving.** `/signup/unsubscribe?t=<fan token>` (`exos_signup_unsubscribe`). Nothing sends to the signup
  list yet: when org list mail is built, every message must carry that link.

## Tags

`exos_tags` (per org; optional `scope` event / fan / artist; optional color; optional link to the seeded
`exos_canonical_tags` library) applied with `exos_tagged_items`. A trigger checks the tagged record belongs to
the org (artists once `exos_artists` exists) and that the tag's scope fits. Filters: the fan list (all chosen
tags), the Tags tab's event list (`exos_org_tag_filter`), and `?tag_id=` on `GET /v1/events` and `/v1/fans`.
Owner / manager write; finance and content read. Through the API, tags are `events:*`, and anything on a fan
also needs `fans:*`. `PUT /v1/tagged-items/:id` moves an assignment to another tag (`tag_id`, or
`tag_attributes[name]` found or made with the record's type), mig 20261105120000.

## Tixel waitlist signups

Mig `20261105120000`, edge function `exos-tixel-webhook` (Opendate's `POST /public/tixel/waitlist_signups`). Tixel
posts fan activity to one URL with the organizer's secret in `X-Secret`. The secrets live in the function's env,
never in the database: `EXOS_TIXEL_WEBHOOK_SECRETS` = `{"<org id>": "<secret of 16+ characters>", …}`; the secret
picks the organization, and with the variable unset the function answers 404. Only `WAITLIST` is kept
(`PURCHASE`, `AUTO_PURCHASE`, `LISTING` get 200 so Tixel doesn't retry); no `user.email` is 422. A signup is stored
in `exos_tixel_signups` (owner / manager read) and, when exactly one upcoming published event of the org has the
Tixel event title as its name (case-insensitive), put on that event's waitlist (`exos_waitlist`, `meta.source =
'tixel'`). Redelivery of the same payload answers the first result. Tixel's `marketingConsent` is not applied: consent
changes only by the fan. Inbound only: nothing is sent to Tixel. 32 KB a body, 120 deliveries a minute per org.

## Refund requests

Fans ask from the ticket page (`RefundAskCard`, `exos_ask_refund`, mig 20261015090000) within the event's refund
policy; My Tickets now lists every ask with its status and the organizer's note, and an open one can be taken
back (`exos_my_refund_asks_all`). Staff see one queue across events on the **Refund requests** tab
(`exos_org_refund_asks`, owner / manager / finance). **Refund** runs the existing refund: `exos-refund` with
nonce `ask:<id>` (Stripe, the ticket voided, the refund mail), and the ask closes when that refund succeeds.
**Decline** is the existing `exos_decline_refund_ask`, with a note the buyer sees. Nothing new moves money.
`GET /v1/refund-requests` (`orders:read`) reads the queue; deciding needs a signed-in staff member.

## Opendate endpoints

How each Opendate endpoint in these areas maps to Exos.

| Opendate | Exos | Notes |
|---|---|---|
| `GET /api/v2/fans` (and `/confirms/{id}/fans`) | `GET /v1/fans` | `q`, `email`, `tag_id`, `updated_after`, `order_by`/`order`, paging. Per event: `GET /v1/orders?event_id=` / `/v1/events/:id/attendees` |
| `GET /api/v2/fans/{id}` | `GET /v1/fans/:id` | |
| `GET /api/v2/fans/{id}/organizer_detail` | `GET /v1/fans/:id` | The same payload carries orders, money, consent, tags, signups. No memberships or giving in Exos |
| `POST /api/v2/fans` | `POST /v1/fans` | Email + names; on no list |
| `GET /api/v2/fans/lookup` | `GET /v1/fans/lookup` | Partial, AND, at most 3 |
| `GET /api/v2/confirms/{id}/fans/recommendations` | not built | No recommendation model yet; tags and past buyers (`/v1/orders`) are the inputs one would use |
| `PUT /api/v2/fans/{id}/update_marketing_subscriptions` | deliberately not provided | Consent changes only by the fan (unsubscribe link, profile toggle, SMS STOP) |
| `POST /api/v2/public/fans` | `POST /functions/v1/exos-signup` | With a signup form id; the venue-id mode and free tags aren't taken (the form decides) |
| `POST /forms/{uuid}/submissions` | `POST /functions/v1/exos-signup/forms/{uuid}/submissions` | Same field names; custom questions (`answers[...]`) not built |
| `GET /api/v2/public/confirm_fan_infos/{id}` | `exos_public_events` (anon view), the listing feed's `GET /v1/public/events/:id` (PR #69) | Lookup by order number isn't offered (it would confirm an order exists); fans use My Tickets |
| `GET /api/v2/public/orders/{id}/refund_request` | `exos_my_refund_asks(event)`, `exos_my_refund_asks_all()` | Signed in (the payer's account or confirmed email), not shared key + typed email |
| `POST /api/v2/public/orders/{id}/refund_request` | `exos_ask_refund(ticket_ids, reason)` | Per ticket, within the refund policy |
| `POST /api/v2/public/tixel/waitlist_signups` | `exos-tixel-webhook` (POST) | Into `exos_waitlist` for the event with that title; the secret is an env var ("Tixel waitlist signups" above) |
| `GET /api/v2/admin/fans` | `GET /v1/fans` | Per org (the key's); no cross-org admin API |
| `GET /api/v2/admin/fans/:id` | `GET /v1/fans/:id` | |
| `POST /api/v2/admin/fans` | `POST /v1/fans` | |
| `PATCH /api/v2/admin/fans/:id` | `PATCH /v1/fans/:id` | Names only |
| `DELETE /api/v2/admin/fans/:id` | `DELETE /v1/fans/:id` | Soft delete, as Opendate's discard |
| `GET /api/v2/tags` | `GET /v1/tags` | `scope` filter |
| `GET /api/v2/tags/{id}` | `GET /v1/tags/:id` | |
| `POST /api/v2/tags` | `POST /v1/tags` | |
| `PUT /api/v2/tags/{id}` | `PATCH /v1/tags/:id` | |
| `DELETE /api/v2/tags/{id}` | `DELETE /v1/tags/:id` | |
| `GET /api/v2/tagged_items` | `GET /v1/tagged-items` | `taggable_type` accepts `CalendarEvent` |
| `GET /api/v2/tagged_items/{id}` | `GET /v1/tagged-items/:id` | |
| `POST /api/v2/tagged_items` | `POST /v1/tagged-items` | `tag_id` or `tag_attributes[name]` |
| `PUT /api/v2/tagged_items/{id}` | `PUT /v1/tagged-items/:id` | Moves the assignment to another tag (by id or name) |
| `DELETE /api/v2/tagged_items/{id}` | `DELETE /v1/tagged-items/:id` | |
| `GET /api/v2/canonical_tags` | `GET /v1/canonical-tags` | Seeded library: genres, audiences, formats, age rules |
| `GET /api/v2/public/discovery/confirms` | `exos_public_events` view; listing feed `GET /v1/public/events` (PR #69) | |
| `GET /api/v2/public/discovery/confirms/{id}` | `exos_public_events` + `exos_public_tiers` | |
| `GET /api/v2/public/venues` | `exos_public_orgs` | Exos organizers are the venues |
| `GET /api/v2/public/venues/{id}` | `exos_public_orgs` + the org's public events | |
| `GET /api/v2/public/search` | `exos_public_events` / `exos_public_orgs` with `ilike` | No search RPC needed |
| `GET /api/v2/users/current/tickets` | `exos_tickets` (RLS: the holder), `listMyTickets` | |
| `GET /api/v2/users/current/tickets/{barcode}` | `exos_tickets` by id, `exos_ticket_barcode_secrets` for the rotating code | Keyed by ticket id: Exos codes rotate |
| `GET /api/v2/users/current/tickets/{barcode}/pkpass` | `exos-wallet` `POST /pass { ticket_id, kind: "apple" }` | |
| `GET /api/v2/users/current/ticket_bundles` | `exos_my_ticket_bundles()` | New: tickets grouped by event, no barcode secret |
| `GET /api/v2/users/current/ticket_bundles/{id}` | `exos_my_ticket_bundles(event_id)` | |
| `GET /api/v2/users/current/memberships`, `/{token}` | not applicable | No membership products in Exos yet |
| `GET /api/v2/users/current/season_passes`, `/{id}`, `/{id}/pkpass`, `/{id}/google_wallet_url` | not applicable | No season passes yet |
| `GET /api/v2/users/current/passes`, `/{id}` | not applicable | No flex packs yet |
