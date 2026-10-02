# Security: database RPC surface

Exos's browser client talks to Postgres through PostgREST, so every function
that `anon` or `authenticated` may EXECUTE is callable as
`POST /rest/v1/rpc/<name>`. Most Exos logic runs in `SECURITY DEFINER`
functions (they bypass RLS), so each one has to check who is calling.

This page records the audit of the Supabase security advisor findings for
Exos on the shared project (2026-09-28), what
`supabase/migrations/20260929080000_exos_rpc_hardening.sql` changed, and the
settings an operator has to change in the dashboard because code can't.

The tests are in `tests/exos/test_rpc_hardening.sql` (wired into
`tests/exos/run_p0.sh`). H3 in that file fails if a new anon-callable definer
function appears outside the intended public set, so an addition has to be
reviewed and added to its allowlist.

## Rules for new functions

- Every `SECURITY DEFINER` function sets `SET search_path = public, pg_temp`
  (test H1 checks all of them).
- `REVOKE ALL ... FROM PUBLIC, anon, authenticated`, then grant only the roles
  that call it. Helpers used only by other definer functions, definer views,
  cron jobs or edge functions (service role) get no client grant.
- A client-callable function checks the caller first: `auth.uid()` for
  self-service, `exos_has_org_role(...)` or `exos_can_door_event(...)` for
  staff actions, a bearer token for links. Look the row up, then check the
  caller against *that row's* org or owner, never against an id the caller
  passed in.
- Anon writes must be gated by an unguessable token (`gen_random_uuid()` or
  more) or rate-limited (`exos_rate_hit`, `exos_voucher_throttle`).
- Don't return emails or phone numbers except to org staff who need them
  (mask with `exos_mask_email` / `exos_rr_mask_email` otherwise).

## Verdicts

Legend: **OK** = intended and properly checked; **Revoked** = internal helper,
client EXECUTE removed; **Fixed** = body patched in 20260929080000.

### Callable by anon (23 flagged)

| Function | Verdict | Why |
|---|---|---|
| `exos_addon_exclusive_tax_percent` | Revoked | Tax rate for any add-on id (drafts, hidden). Only definer view `exos_public_addons` needs it, and that view runs as its owner |
| `exos_tier_exclusive_tax_percent` | Revoked | Same, for any tier; used by `exos_public_tiers` (definer view) and definer functions |
| `exos_tier_is_table` | Revoked | Internal; answered for any tier id |
| `exos_tier_party_size` | Revoked | Internal; only definer functions (and `exos_assert_quota`, called by definer functions) use it |
| `exos_event_is_published` | OK | Boolean only; backs the anon tier-read policy `exos_tiers_public_read`, so anon must keep it |
| `exos_check_voucher` | Signed-in only | Throttled by `exos_voucher_throttle` (10 misses / 10 min per account). Applying a code needs an account (decision 2, 2026-09-29); `exos-checkout` refuses a code from a guest |
| `exos_voucher_discount`, `exos_voucher_tier` | Signed-in only | Go through `exos_check_voucher` (same throttle) |
| `exos_invite_preview` | OK | Bearer `gen_random_uuid()` invite token; returns org, role, status, expiry |
| `exos_leave_waitlist` | Revoked (anon) | A no-op for anon (matches only the caller's uid or verified JWT email). Signed-in use unchanged |
| `exos_mail_unsubscribe` | OK | 64-hex token (two UUIDv4s), format-checked; only sets the opt-out |
| `exos_promoter_kit`, `_earnings`, `_guest_lists`, `_limit_flags` | OK | Promoter kit token (`gen_random_uuid()`), `status = 'active'`, rotatable (`exos_set_promoter_status(..., rotate)`). Guest lists omit email/phone; limit flags mask the buyer email |
| `exos_promoter_add_guest`, `_remove_guest`, `_set_guest_access_needs`, `_note_limit_flag`, `_set_socials` | OK | Anon writes gated by the kit token and `_exos_promoter_list` (list must be the promoter's, open, and on a live event); guest adds count against the list cap when one is set |
| `exos_public_promoter` | OK | Public promoter page: name, code, socials only if `allow_tagging` |
| `exos_public_table_tiers` | OK | Public table tiers of published events only |
| `exos_transfer_claim_preview` | OK | By transfer id (UUIDv4): event title, image, tier and status, no emails. Claiming still needs the key or the addressed account. Since mig 20261002101500 a pending transfer whose event is over reads `expired` |

### Callable by authenticated (131 flagged)

Grouped by the check they rely on. All pin `search_path`.

| Function(s) | Verdict | Why |
|---|---|---|
| `exos_channel_allocated`, `exos_event_house_available` | Revoked | Unscoped inventory counts for any tier or event (drafts included); only definer functions use them |
| `exos_redeem_discount_code` (prod only, legacy) | Revoked | Unthrottled code-guessing oracle on the old `exos_discount_codes`; nothing calls it |
| `exos_check_in_offline` | Fixed | Wrote the client ref (and, for another org's ticket, a scan-reject row in that org's door log) before the staff check, and read another device's cached result by client ref. Now requires owner / manager / scanner on the event's org first |
| `exos_queue_mail` | Fixed | Mail-bombing: a sender could re-queue the "someone sent you a ticket" or invite mail to an arbitrary address without limit. Now the same mail to the same address within 10 min returns the queued one, and a caller queues at most 10 a minute. The transfer mail's link also carries `?k=<claim_key>` now, so any account can claim from it as the mail says (before, only the addressed account could); who may queue it is unchanged |
| `exos_create_org` | Fixed | No cap: any account could create organizations and claim slugs without limit. Now at most 3 per 24 hours and 20 in all per account (orgs it created or owns); platform admins are exempt |
| `exos_queue_ticket_issued` | Fixed | Same: one "ticket ready" mail per event and address per 10 min, shared 10/min per-caller limit |
| `exos_has_org_role`, `exos_holds_ticket`, `exos_pos_can_ring`, `_exos_guest_list_can_edit` | OK | RLS policy predicates, scoped to `auth.uid()`; policies evaluate them as the caller, so authenticated keeps EXECUTE |
| `exos_can_door_event`, `exos_can_read_ticket_secret`, `exos_ticket_access_needs`, `exos_transfer_claim_key` | OK | Self-scoped: answer only about the caller (door access, own ticket, own transfer's key) |
| `exos_add_guest`, `exos_update_guest`, `exos_remove_guest`, `exos_upsert_guest_list`, `exos_delete_guest_list`, `exos_set_guest_access_needs` | OK | Org role on the list's org (or list owner via `_exos_guest_list_can_edit`) |
| `exos_assign_table`, `exos_cancel_table_booking`, `exos_event_tables` | OK | Org role on the event's org (booker may cancel their own). `exos_event_tables` shows buyer email to owner / manager / finance only |
| `exos_check_in_ticket`, `exos_guest_check_in`, `exos_undo_check_in`, `exos_event_checkin_roster`, `exos_event_door_extras`, `exos_set_checkin_test_window`, `exos_set_scanner_events` | OK | Door role + per-event scanner scope (`exos_can_door_event`); undo and typed overrides are manager-only; roster has no buyer email (mig 20260925013000) |
| `exos_door_checkin_by_name` (mig 20260929130000) | OK | Check in by name: door role on the event's org, then the event's `door_name_checkin` (`staff` = any door role, `managers` = owner / manager, `off` = refused), then the per-event scanner scope. Any active ticket of the event; the note is optional. A parked (unclaimed) ticket's claim link is cancelled; only a platform parking qualifies (pending transfer sent by the ticket's owner-buyer, an org owner / manager, to the ticket's own `buyer_email`), so a holder's own transfer is refused `in-transfer`. Logged as verification `name`. The roster shows parked tickets' claim name and a masked email (`exos_mask_email`), never the full address or the claim key |
| `exos_check_in_ticket` (10 args), `exos_check_in_offline` (10 args), `exos_door_checkin_by_name` (8 args) (mig 20260929140000) | OK | Check-in lists and optional re-entry: new overloads with `p_list_id`, `p_direction` and **no defaults** (with defaults a call with the old argument count would match both versions); the 8 / 8 / 6 argument versions are unchanged for old clients. Same checks as before (door role on the ticket's org, per-event scanner scope, manager + reason for typed overrides, name check-in setting), then the list: it must be the ticket's event's (`unknown-list`), admit the ticket's tier (`wrong-list`) and, for entries, be inside its window (`invalid-time`); exits only on a list with `allow_reentry` (`exit-not-allowed`), which is off by default. Replay window: 24 h, or until the event's end + 48 h (7 days at most). A refused offline entry (voided, doors, too old, wrong list / time, mid-transfer, a code signed for a previous holder) is also written as a forced check-in (`forced`, `conflict`) by `_exos_record_forced_checkin`, only for a ticket of the event and a caller who may door it; it never changes the ticket. `used` / `already-inside` stay reject-only |
| `exos_event_checkin_roster` (mig 20260929140000) | OK | Same gate (door role + scanner scope); adds `tier_id` and `list_state` (last direction per re-entry list). Still no buyer email |
| `_exos_scan_time_ok`, `_exos_checkin_list_refusal`, `_exos_list_inside`, `_exos_post_transfer_code`, `_exos_record_forced_checkin`, `exos_tg_checkin_list_scope` (mig 20260929140000) | Internal | No client grant; called only from the definer door functions (and the trigger) |
| `exos_checkin_lists` (table, mig 20260929140000) | OK | RLS: owner / manager of the event's org insert, update, delete; door staff of the event read (`exos_can_door_event`, so a scanner assigned to other events sees none). A trigger sets `org_id` from the event, refuses moving a list to another event, and checks the ticket types are the event's. No anon access |
| `exos_record_payment_fees` (mig 20260929131000) | OK | Service role only (stripe-webhook, exos-reconcile-checkouts): stores Stripe's actual fee, net, transfer and balance-transaction ids on `exos_order_payments`; validates ids and never overwrites a value with null. `exos_order_money` is `security_invoker`, readable by owner / manager / finance |
| `exos_record_dispute_event` (mig 20261001101000) | Service role | `stripe-webhook` only. Wraps `exos_record_dispute` (unchanged: session `dispute_*` columns, payment meta, closed states final, same return), then upserts the `exos_disputes` row (ids format-checked, `raw` reduced to an allowlist by `_exos_dispute_raw`: no `evidence` block, metadata or buyer data) and queues the organizer mail. The org and event come from the session row, never from the caller |
| `exos_disputes` (table, mig 20261001101000) | OK | RLS: SELECT for platform admins and the org's owner / manager / finance (`exos_has_org_role`, disabled members excluded); no client writes (no INSERT / UPDATE / DELETE grant). No buyer email; the order is the checkout session id |
| `exos_reconcile_stripe_record` (mig 20261001101000) | Service role | `exos-reconcile-stripe` only (cron secret). Upserts issues per (kind, key) from an allowlist of kinds; an issue's org is always its session's org when there is a session (a passed `org_id` is used only when there's no session and the org exists); resolves only open issues inside the passed window; at most 5,000 issues a call |
| `exos_expire_transfers` (mig 20261002101500) | Service role | Hourly cron. Marks pending transfers on events that are over `expired` and clears the ticket's `pending_transfer_id` (only when it still points at that transfer), so the ticket is the sender's again. `session_user` check, at most 10,000 a run, `SKIP LOCKED`. `_exos_event_over` (no client grant) and the trigger `exos_tg_transfer_expiry` refuse a claim, and a signed-in user's new transfer, once the event is over |
| `exos_reconciliation_issues_for` (mig 20261001101000) | OK | Signed in only. Platform admin: any org, or all with `NULL`. Otherwise the caller must be owner / finance of the passed org (`exos_has_org_role`), and only that org's issues come back; manager, scanner and other orgs are refused (42501). No anon grant |
| `exos_reconciliation_issues`, `exos_stripe_balance_txns`, `exos_reconciliation_runs` (tables, mig 20261001101000) | OK | Issues: RLS SELECT for platform admins and the org's owner / finance; org-less issues (a Stripe charge Exos has no row for) are admin only; no client writes. The Stripe snapshot and the runs: RLS on, no `anon` / `authenticated` grants (service role only) |
| `_exos_queue_dispute_mail`, `_exos_dispute_raw`, `_exos_jscalar` (mig 20261001101000) | Internal | No client grant. The mail helper never raises (a failure is a WARNING), so it can't fail the webhook |
| `exos_org_audience_export` (mig 20260930101000) | OK | Owner / manager of the passed org (`exos_has_org_role`; finance, scanners and platform admins without a role are refused); `p_event_id` must be that org's event. Returns one jsonb of SHA-256 hashes only (email lower-cased and trimmed; phone as E.164 and digits-only), never an address or number, for buyers who granted advertising consent at checkout or follow the org from a signed-in account, minus anyone whose latest choice was `denied`, who unsubscribed (`exos_mail_prefs`, by account or email) or deleted their account. Throttled (3 a minute per org via `exos_rate_hit`, 20 a day per org) and logged in `exos_audience_exports` (RLS: owner / manager read, no client writes) |
| `exos_reschedule_event` (8 args, mig 20260929150000) | OK | Owner / manager (or admin) of the event's org, looked up from the event row (locked). Moves the times, records the reschedule (refund offer + deadline, validated: future and not after the new start) and queues the holder mail in one transaction. The 6-arg version is dropped. `p_offer_refunds` NULL = no refunds |
| `exos_my_reschedule_offers`, `exos_reschedule_release_mine` (mig 20260929150000) | OK | Self: tickets the caller holds or paid for (`auth.uid()`, or the confirmed email of a guest checkout). A refund needs the caller to be the payer (the money goes back to that card), a release the holder. Every rule is re-checked per ticket in `_exos_resched_ticket_state` |
| `exos_event_reschedule_summary` (mig 20260929150000) | OK | Owner / manager / finance (or admin) of the event's org. Counts and amounts only, no buyer emails |
| `exos_request_reschedule_refund`, `exos_reschedule_release_svc`, `exos_reschedule_link_info` (mig 20260929150000) | Service role | Called by `exos-refund` with the verified JWT user or a mail-link token. A token (64 hex, 256 bits, `exos_reschedule_links`, no client grant) acts only on its own ticket, its own action (refund vs release) and the event's latest reschedule; any other ticket id in the same call is refused `not-authorized`. Claims lock the order row like `exos_refund_claim`; one request per ticket + reschedule (nonce `rsr:<reschedule>:<ticket>`), so a repeat returns it. Link info returns no emails |
| `exos_tg_event_date_guard` (trigger), `_exos_resched_ticket_state`, `_exos_resched_actor_ok`, `_exos_reschedule_notify`, `_exos_reschedule_release` (mig 20260929150000) | Internal | No client grant. The trigger refuses a client (`role` authenticated / anon) changing a sold event's start by a qualifying amount except inside `exos_reschedule_event`, so the holder mail can't be skipped |
| `exos_reschedule_qualifies`, `exos_reschedule_default_deadline` (mig 20260929150000) | OK | Plain (not definer) pure functions; authenticated may call them |
| `exos_set_ad_credential`, `exos_list_ad_credentials` (mig 20260930100000) | OK | Server-side ad conversions (`docs/marketing-conversions.md`): owner / manager of the passed org (or admin) via `exos_has_org_role`; the credential row is keyed by that org. The access token goes to Supabase Vault (`vault.create_secret` / `update_secret`, name `exos_ad:<org>:<platform>`); the row keeps only `secret_id`. Write-only: NULL keeps it, `''` removes it; the list returns ids, `has_secret`, enabled and 30-day counts, never the token. Ids are format-checked per platform (`_exos_ad_config_ok`); enabling needs the required ids and a token |
| `exos_org_ad_credentials`, `exos_marketing_conversions` (tables, mig 20260930100000) | OK | RLS on, no `anon` / `authenticated` grants (service role only). The outbox holds hashed email, click / browser ids and the user agent, never a raw email or IP |
| `exos_conversions_claim_batch`, `exos_conversions_mark` (mig 20260930100000) | Service role | `exos-conversions-drain` only. The claim decrypts each org's token from `vault.decrypted_secrets`; the drain sends it only to the platform's pinned host and redacts it from `payload_planned` and error text. Marks land only with the lease's `claim_token` |
| `exos_oauth_states` (table, mig 20260930102000) | OK | Connect Google Ads (`exos-oauth-google`): RLS on, no `anon` / `authenticated` grants (service role only). Holds the SHA-256 of each OAuth state (never the state), the org, the starting user, a 10-minute expiry and, between Google's callback and `/finish`, the authorization code (cleared when consumed) |
| `exos_oauth_state_begin`, `exos_oauth_state_return`, `exos_oauth_state_consume`, `exos_set_google_ads_token`, `_exos_oauth_can_connect` (mig 20260930102000) | Service role | `exos-oauth-google` only, with the user id from the verified JWT. Begin: owner / manager (active membership) of the org, at most 10 starts per user per 10 minutes. Return: parks the code on a live, unused state once. Consume: only the user who started the state, once, before expiry, while still owner / manager, so a consent link finished in someone else's browser can't attach their Google account to another org. Store: re-checks the role; the refresh token goes to Vault as `exos_ad:<org>:google_ads` (same as `exos_set_ad_credential`), never returned |
| `exos_tg_conversions_checkout`, `exos_tg_conversions_refund`, `_exos_email_sha256`, `_exos_email_sha256_google`, `_exos_ad_required_keys` (mig 20260930100000) | Internal | No client grant. The triggers queue rows only for a fulfilled paid checkout with `consent_marketing = 'granted'` and an enabled platform, and never fail fulfilment or a refund |
| `exos_invoice_document`, `exos_credit_note_document`, `exos_my_invoices` (mig 20261001100000) | OK | Receipts and credit notes (`docs/invoices.md`). The invoice row is looked up first, then the caller is checked against it: owner / manager / finance of the invoice's org (`exos_has_org_role`), or the buyer (`auth.uid()` = the invoice's or the checkout session's buyer, or, for a guest checkout with no buyer account, an account whose **confirmed** email is the order's). No such id and not allowed give the same "not found" (42501). Returns the buyer email only to that buyer or finance-capable staff. `exos_my_invoices` lists only the caller's. No anon grant |
| `exos_org_legal`, `exos_credit_notes`, `exos_credit_note_counters` (tables), `exos_invoice_totals` (view) (mig 20261001100000) | OK | Legal details: RLS owner / manager / finance read and write, no anon grant, not a column of `exos_orgs` (so not in `exos_public_orgs` or visible to scanners). Credit notes: RLS read for the org's owner / manager / finance and the invoice's buyer; no client writes; frozen by trigger. Counters: RLS on, no client grants. The view is `security_invoker` |
| `exos_next_credit_note_number`, `_exos_issue_credit_note`, `_exos_org_seller`, `exos_tg_refund_credit_note`, `exos_tg_invoice_seller`, `exos_tg_invoice_frozen`, `exos_tg_credit_note_frozen`, `exos_tg_org_legal_clean` (mig 20261001100000) | Internal | No client grant; triggers and the definer functions above only |
| `exos_create_event_series`, `exos_notify_event_holders`, `exos_send_event_announcement`, `exos_send_event_reminder_now`, `exos_announce_to_followers`, `exos_event_analytics`, `exos_event_access_requests`, `exos_event_quotas`, `exos_event_refund_orders`, `exos_price_disclosure_export`, `exos_refund_preview` | OK | Org role looked up from the event / order row |
| `exos_mint_tickets`, `exos_issue_comp_batch`, `exos_issue_ticket_to_email`, `exos_issue_voucher`, `exos_void_ticket`, `exos_release_ticket`, `exos_org_comp_usage`, `exos_set_org_comp_budget` | OK | Org role (owner / manager), comp budget enforced |
| `exos_create_api_key`, `exos_list_api_keys`, `exos_revoke_api_key` | OK | Org role; listing shows the prefix only, never the key |
| `exos_upsert_promoter`, `exos_set_promoter_status`, `exos_set_promoter_terms`, `exos_org_promoter_stats`, `exos_org_promoter_commissions`, `exos_record_promoter_payout` | OK | Org role on the promoter's org |
| `exos_set_referral_reward_rule`, `exos_get_referral_reward_rule`, `exos_delete_referral_reward_rule`, `exos_referral_leaderboard` | OK | Org role; leaderboard masks emails |
| `exos_link_channel_event`, `exos_request_distribution`, `exos_set_channel_allocation`, `exos_set_channel_price`, `exos_mark_marketplace_order_handled`, `exos_resend_marketplace_claim_links`, `exos_review_account_limit_flag`, `exos_pool_state` | OK | Org role on the event / listing's org |
| `exos_notify_waitlist`, `exos_waitlist_offer_next`, `exos_waitlist_summary` | OK | Org role |
| `exos_pos_open_tab`, `exos_pos_close_tab`, `exos_pos_close_drawer`, `exos_pos_record_settlement`, `exos_pos_set_86`, `exos_pos_settlement_summary` | OK | Door / POS role on the event's org |
| `exos_create_hold`, `exos_release_hold`, `exos_claim_free_tickets`, `exos_claim_free_addons` | OK | Self (confirmed email for holds), published events and public tiers only, per-buyer limits and capacity enforced |
| `exos_create_transfer`, `exos_cancel_transfer`, `exos_claim_transfer(uuid)`, `exos_claim_transfer(uuid, text)` | OK | Owner / sender checks; claiming needs the 128-bit claim key (compared as SHA-256 digests) or the addressed, verified account |
| `exos_claim_invite` | OK | UUIDv4 invite token, expiry, verified email; never demotes an owner |
| `exos_join_waitlist`, `exos_attach_referral`, `exos_my_referral_code`, `exos_my_referral_progress`, `exos_my_referral_stats`, `exos_redeem_referral_reward` | OK | Self (`auth.uid()`); the waitlist uses the session's verified email, not a passed one |
| `exos_set_ticket_attendee`, `exos_set_ticket_access_needs`, `exos_wallet_issue_pass`, `exos_wallet_reissue` | OK | Ticket owner only |
| `exos_calendar_feed_token_create`, `_revoke`, `_status`, `exos_set_marketing_emails`, `exos_mark_notifications_read`, `exos_follow_org`, `exos_unfollow_org`, `exos_delete_my_account` | OK | Self-service on the caller's own rows |
| All anon-callable functions above | as above | authenticated also holds them |

Everything else in the advisor's Exos list (triggers `exos_tg_*`, cron and
webhook workers, `exos_record_*`, `exos_refund_*`, wallet / calendar / MCP
service functions, `_exos_*` internals) was already revoked from anon and
authenticated and is service-role or owner only.

### Search path

`exos_platform_fee_bps()` (a plain `SELECT 300`) was the one Exos function
without a pinned `search_path`; it now has `public, pg_temp`.

### SECURITY DEFINER views (8, by design)

`exos_public_*` are column projections of published rows for buyers; they run
as their owner so anon needs no grant on the base tables or the tax helpers.
`exos_ticket_barcode_secrets` and `exos_ticket_buyer_emails` filter rows
internally (`exos_can_read_ticket_secret`, `exos_has_org_role`). Don't flip
them to `security_invoker` to quiet the advisor: anon would then need SELECT
on the base tables and EXECUTE on the helpers revoked above, which is exactly
what these views avoid.

## Operator settings (dashboard, not code)

These can't be set from a migration. Project: the shared Supabase project
(`hzrizjeaxlqcxfrtczpq`), so they also affect Terminal-2's users.

| Setting | Where | Recommendation |
|---|---|---|
| Leaked password protection | Authentication → Attack Protection (Password security) | Turn on: rejects passwords found in HaveIBeenPwned. The advisor flags it as off |
| Minimum password length and strength | Authentication → Sign In / Providers → Email | At least 8 characters with mixed character classes |
| Confirm email | Authentication → Sign In / Providers → Email | Keep on. Holds, waitlist, transfers and invites rely on `email_confirmed_at` |
| MFA (TOTP, optionally phone) | Authentication → Multi-Factor | Enable TOTP so org owners and finance can enrol. RLS doesn't require AAL2 yet; requiring it for owner / finance actions is a code follow-up |
| CAPTCHA on sign-up / sign-in / password reset | Authentication → Attack Protection | Turn on (Turnstile or hCaptcha). The voucher throttle and mail limits are per account, so cheap account farming weakens them |
| Auth rate limits | Authentication → Rate Limits | Keep the defaults or lower them for sign-up and OTP emails |
| Custom SMTP | Authentication → Emails → SMTP | Use the transactional provider so auth mail isn't capped by the built-in sender |
| JWT expiry | Project Settings → JWT / API | 3600 s (default) or less |
| Postgres upgrades | Project Settings → Infrastructure | Apply security patch releases when the advisor reports one |

## Open decisions

1. **Apply 20260929080000 to prod.** It's re-run safe; prod needs explicit
   operator permission.
2. **Voucher codes need an account (decided 2026-09-29).** Signed-out
   buyers used to share one 60-miss bucket per event, so a guesser could
   also lock everyone else out of codes. Now anon can't run the voucher RPCs,
   `exos-checkout` answers 401 "sign in to use a code" to a guest, and the
   code field asks for sign-in (the emailed 6-digit code keeps the buyer on
   the page) and applies the code once they're in. Guest checkout without a
   code is unchanged. CAPTCHA on sign-up matters more now: accounts are the
   throttle's unit.
3. **Org creation caps** (3 a day, 20 per account, admins exempt) are a
   judgement call. Raising them is a one-line change in `exos_create_org`;
   anyone who hits them sees a message asking them to contact support.
