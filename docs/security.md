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
| `exos_transfer_claim_preview` | OK | By transfer id (UUIDv4): event title, image, tier and status, no emails. Claiming still needs the key or the addressed account |

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
| `exos_door_admit_parked` (mig 20260929130000) | OK | Will-call for parked (unclaimed) tickets: door role on the event's org, then owner / manager on the ticket's org plus the per-event scope, with a reason. Only a platform parking qualifies (pending transfer sent by the ticket's owner-buyer, an org owner / manager, to the ticket's own `buyer_email`), so a holder's own transfer can't be short-circuited. The roster shows parked tickets' claim name and a masked email (`exos_mask_email`), never the full address or the claim key |
| `exos_create_event_series`, `exos_reschedule_event`, `exos_notify_event_holders`, `exos_send_event_announcement`, `exos_send_event_reminder_now`, `exos_announce_to_followers`, `exos_event_analytics`, `exos_event_access_requests`, `exos_event_quotas`, `exos_event_refund_orders`, `exos_price_disclosure_export`, `exos_refund_preview` | OK | Org role looked up from the event / order row |
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
