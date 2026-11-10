#!/usr/bin/env bash
# P0 regression run (2026-09-24): every *exos* migration, in timestamp order,
# on a scratch Postgres (see the comment above the apply loop), then the SQL
# suites, then the replay loop and the suites that run after it.
#   bash tests/exos/run_p0.sh <db>
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR/../../supabase/migrations"
psql -h "$H" -p "$P" -U "$U" -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
PSQL="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -q"
# The database is built the way prod was: Supabase's own pieces (roles, auth,
# pgcrypto, storage, realtime, vault) are stubbed, then EVERY *exos* migration
# runs in timestamp order, phase-1 schema on (2026-11-09; before that the chain
# started from a hand-stubbed prereq.sql and skipped the 34 migrations up to
# 20260924200848, so text patches met bodies prod never had; see
# supabase/README.md migration rule 4). No exos_* object is stubbed.
$PSQL -f "$DIR/prereq_lifecycle.sql"
$PSQL -f "$DIR/prereq_supabase.sql"
$PSQL -f "$DIR/prereq_vault.sql"
# apply <migration>: one migration, with the few harness shims some need
# around them. Never edits a migration; each shim is explained in its file.
apply() {
  case "$1" in
    # cron.unschedule + cron.schedule, unguarded (later migrations guard on
    # pg_extension): a pg_cron stub for this file only, dropped right after.
    20260702144637_exos_reconcile_checkouts_cron) $PSQL -f "$DIR/shim_cron.sql" ;;
    # Its view puts artist_links mid-list, which can't replace the phase-1
    # view; prod has it appended last (see shim_artist_links_view.sql).
    20260703130000_exos_event_artist_links) $PSQL -c 'DROP VIEW public.exos_public_events' ;;
    # Prod's bodies of exos_queue_mail / exos_queue_ticket_issued /
    # exos_create_org as of 2026-09-28 (Terminal-2-era prod-only edits on
    # top of migs 20260520160000 / 20260523210000), the text this one patches.
    20260929080000_exos_rpc_hardening) $PSQL -f "$DIR/prereq_rpc_hardening.sql" ;;
    # Terminal-2's 20260526020000_fix_checkins_scanned_by_nullable, the one
    # Terminal-2 migration that changes an exos_* column (rule 3), at its
    # place in the timeline.
    20260601120500_sec_p3_document_exos_public_views_accepted)
      $PSQL -c 'ALTER TABLE public.exos_event_checkins ALTER COLUMN scanned_by DROP NOT NULL' ;;
    # Prod's leftovers it cleans up (exos_paste_probe, anon EXECUTE on two
    # helpers) and the policy set before it, for test_security_hygiene.sql.
    20261109110000_exos_security_hygiene) $PSQL -f "$DIR/shim_security_hygiene.sql" ;;
  esac
  $PSQL -f "$MIG/$1.sql"
  case "$1" in
    20260702144637_exos_reconcile_checkouts_cron) $PSQL -c 'SET client_min_messages = warning; DROP SCHEMA cron CASCADE' ;;
    20260703130000_exos_event_artist_links) $PSQL -f "$DIR/shim_artist_links_view.sql" ;;
  esac
}
for m in \
  20260520120000_exos_phase1_schema \
  20260520130000_exos_phase2_tickets \
  20260520140000_exos_org_follows \
  20260520150000_exos_storage \
  20260520160000_exos_mail \
  20260523120000_exos_realtime_checkins \
  20260523130000_exos_mail_drainer \
  20260523150000_exos_mint_event_cap \
  20260523160000_exos_check_in_verify \
  20260523170000_exos_stripe_checkout \
  20260523180000_exos_purchase_limits \
  20260523190000_exos_distribution \
  20260523200000_exos_growth_primitives \
  20260523210000_exos_mail_ticket_issued \
  20260523220000_exos_notify_holders \
  20260523230000_exos_issue_to_email \
  20260524150000_exos_public_marketing \
  20260524160000_exos_security_hardening \
  20260601120500_sec_p3_document_exos_public_views_accepted \
  20260605131000_exos_media_restrict_anon_listing \
  20260605131500_exos_checkins_scanned_by_email \
  20260605132000_exos_check_in_event_scope \
  20260605132500_exos_claim_free_tickets \
  20260616180000_exos_waitlist \
  20260616190000_exos_addons \
  20260616200000_exos_public_api_webhooks \
  20260616210000_exos_vouchers \
  20260616220000_exos_waitlist_autoassign \
  20260616230000_exos_tax \
  20260616240000_exos_invoicing \
  20260616250000_exos_voucher_bypass_fulfill \
  20260622210000_exos_public_views_security_invoker \
  20260702120000_exos_checkin_harden_doors_gate \
  20260702121000_exos_transfer_secret_leak_fix \
  20260702122000_exos_voucher_singleuse_and_limit_atomic \
  20260702123000_exos_barcode_secret_least_privilege \
  20260702123000_exos_cart_holds \
  20260702123030_exos_quotas \
  20260702123100_exos_payment_ledger \
  20260702123200_exos_tier1_wiring \
  20260702144537_exos_checkin_test_window_autoexpiry \
  20260702144607_exos_waitlist_idor_fix \
  20260702144637_exos_reconcile_checkouts_cron \
  20260702240000_exos_event_checkin_roster_rpc \
  20260703120000_exos_event_saves \
  20260703121000_exos_event_announcements \
  20260703122000_exos_tier_price_schedule \
  20260703123000_exos_announcement_retract \
  20260703124000_exos_event_reschedule \
  20260703130000_exos_event_artist_links \
  20260703150000_exos_mail_template_reconcile \
  20260709120000_exos_notification_reads \
  20260709120100_exos_org_country_currency \
  20260911050000_exos_invoice_counters_rls \
  20260911051000_exos_event_reminders \
  20260911060000_exos_ticket_attendee_name \
  20260911070000_exos_event_reminders_hardening \
  20260911130000_exos_event_analytics \
  20260911131000_exos_rsvp_release \
  20260911132000_exos_comp_batch \
  20260911133000_exos_event_series \
  20260911134000_exos_roster_attendee_name \
  20260924200848_exos_audit_hardening_quota_transfer_waitlist \
  20260924205115_exos_p0_refund_ledger \
  20260924205508_exos_p0_voucher_per_ticket \
  20260924205916_exos_p0_hold_caps \
  20260924210103_exos_p0_quota_aware_mints \
  20260924211840_exos_all_in_price_tax \
  20260924215000_exos_fulfill_all_or_nothing \
  20260924223000_exos_checkout_attribution \
  20260924230000_exos_event_geo \
  20260924233000_exos_promoters \
  20260924234500_exos_fan_referrals \
  20260925000000_exos_voucher_unlocked_tier \
  20260925001000_exos_event_series_codes_fix \
  20260925003000_exos_trial_run_fixes \
  20260925010000_exos_trial_run_fixes_2 \
  20260925012000_exos_presale_vouchers \
  20260925013000_exos_scanner_no_buyer_email \
  20260925020000_exos_webhook_claim \
  20260925021000_exos_p1_db_hardening \
  20260926000000_exos_advisor_cleanup \
  20260926010000_exos_waitlist_signin_account_deletion \
  20260926020000_exos_promoter_commissions \
  20260926030000_exos_referral_rewards \
  20260926040000_exos_organizer_refunds \
  20260926050000_exos_tables_guest_lists \
  20260926060000_exos_abandoned_checkout \
  20260926070000_exos_price_disclosure \
  20260926080000_exos_refund_tables_fix \
  20260926090000_exos_accessible_tickets \
  20260926190000_exos_stubhub_event_request \
  20260926191000_exos_channel_event_links \
  20260926192000_exos_marketplace_orders \
  20260926193000_exos_channel_allocations \
  20260926194000_exos_listing_plan_account_flags \
  20260927010000_exos_claim_any_account \
  20260927020000_exos_seatgeek_channel_label \
  20260927030000_exos_marketplace_sync \
  20260927040000_exos_gametime_channel \
  20260927050000_exos_marketplace_standard \
  20260928010000_exos_marketplace_pools \
  20260928020000_exos_gotickets_channel \
  20260928030000_exos_vivid_channel \
  20260928040000_exos_marketplace_scarcity \
  20260928050000_exos_guest_checkout \
  20260928060000_exos_voucher_discounts_quota_editor \
  20260928070000_exos_tevo_channel \
  20260928080000_exos_tevo_inventory \
  20260929010000_exos_security_hardening \
  20260929020000_exos_pool_refill_order \
  20260929030000_exos_money_path_fixes \
  20260929040000_exos_door_hardening \
  20260929041000_exos_event_scanner_scope \
  20260929050000_exos_marketplace_sale_note \
  20260929051000_exos_marketplace_attention \
  20260929052000_exos_marketplace_pricing \
  20260929060000_exos_mcp \
  20260929061000_exos_market_split \
  20260929062000_exos_marketplace_fees \
  20260929070000_exos_payout_ledger \
  20260929071000_exos_mail_templates \
  20260929072000_exos_wallet_passes \
  20260929073000_exos_calendar_feeds \
  20260929074000_exos_pos_scaffold \
  20260929080000_exos_rpc_hardening \
  20260929120000_exos_event_store_content \
  20260929130000_exos_door_name_checkin \
  20260929131000_exos_checkout_records \
  20260929140000_exos_door_lists \
  20260929150000_exos_reschedule_refunds \
  20260930100000_exos_marketing_conversions \
  20260930101000_exos_audience_export \
  20260930102000_exos_oauth_google \
  20261001100000_exos_invoices_credit_notes \
  20261001101000_exos_disputes_reconciliation \
  20261005090000_exos_online_events \
  20261008090000_exos_door_delta_summary \
  20261008100000_exos_public_view_tax_grants \
  20261013090000_exos_door_imports \
  20261013100000_exos_eventbrite_sync \
  20261014090000_exos_auto_channel_split \
  20261014100000_exos_s4k_feed \
  20261014110000_exos_eventbrite_inventory \
  20261014120000_exos_eventbrite_checkins \
  20261014130000_exos_s4k_pools \
  20261014140000_exos_resale_min_capacity \
  20261014150000_exos_s4k_listings \
  20261014160000_exos_public_tier_available \
  20261015090000_exos_refund_asks \
  20261016090000_exos_org_integrations \
  20261016100000_exos_ticket_backends \
  20261016110000_exos_promo_links \
  20261016120000_exos_sms \
  20261016130000_exos_white_label \
  20261019090000_exos_channel_mirrors \
  20261019100000_exos_door_day_keys \
  20261019110000_exos_online_event_followups \
  20261019120000_exos_door_roster_wallet_delta \
  20261027080000_exos_public_tier_available_grant \
  20261027090000_exos_api_scopes \
  20261027100000_exos_fee_rules \
  20261029090000_exos_free_tier_resale_consent \
  20261029100000_exos_last_call \
  20261029120000_exos_weekly_channel_report \
  20261029130000_exos_discovery_publishing \
  20261029140000_exos_eventbrite_oauth \
  20261029150000_exos_posh_webhooks \
  20261029160000_exos_fixed_block \
  20261029170500_exos_event_import \
  20261030100000_exos_booking \
  20261030110000_exos_artists_feed \
  20261030120000_exos_sales_counts \
  20261030130000_exos_gift_cards_giving \
  20261030130500_exos_passes_memberships \
  20261030140000_exos_seating \
  20261030150000_exos_series_timed_entry \
  20261031100000_exos_offers \
  20261031100500_exos_settlements \
  20261031110000_exos_core_api \
  20261031120000_exos_fans \
  20261031130000_exos_partner_sales \
  20261031130500_exos_developer_platform \
  20261031210000_exos_matched_seats \
  20261031220000_exos_payments_paypal_cashapp_split \
  20261031230000_exos_group_chat \
  20261101000000_exos_integration \
  20261102100000_exos_membership_writes \
  20261102110000_exos_giving_writes \
  20261102120000_exos_finance_extras \
  20261102130000_exos_templates_inbound \
  20261102140000_exos_order_edits_recs \
  20261102150000_exos_promoter_wedge \
  20261102160000_exos_gaps_integration \
  20261104100000_exos_sim_buyer_fixes \
  20261104110000_exos_sim_organizer_fixes \
  20261104120000_exos_sim_door_fixes \
  20261104130000_exos_sim_partner_fixes \
  20261104150000_exos_posh_link_channel \
  20261104180000_exos_org_access \
  20261104190000_exos_commission_methods \
  20261104200000_exos_small_ops \
  20261105100000_exos_sim_decisions \
  20261105110000_exos_fan_api \
  20261105120000_exos_na_build \
  20261105130000_exos_promoter_events \
  20261105140000_exos_ig_checkout \
  20261105150000_exos_wave3_integration \
  20261105160000_exos_token_lineage \
  20261106100000_exos_dice_import \
  20261106110000_exos_checkout_questions \
  20261106120000_exos_shared_capacity \
  20261106130000_exos_price_steps \
  20261106140000_exos_buyer_geo_genre \
  20261107100000_exos_pos_walkup \
  20261107110000_exos_dice_gaps_6 \
  20261107120000_exos_partner_steps \
  20261107130000_exos_pos_terminal \
  20261108100000_exos_money_journal \
  20261108110000_exos_dice_leftovers \
  20261108120000_exos_group_pay \
  20261108130000_exos_claim_alias_fix \
  20261109100000_exos_org_audit \
  20261109110000_exos_security_hygiene \
  20261110100000_exos_journal_complete \
  20261110110000_exos_group_pay_2 \
  20261110120000_exos_leftovers_9 \
  20261111100000_exos_e2e_fixes \
  20261111110000_exos_neighborhoods \
  20261111120000_exos_group_pay_off \
  20261111130000_exos_journal_payouts_tax \
  20261111140000_exos_api_leftovers \
  20261112100000_exos_follower_fixes \
  20261113110000_exos_fair_day; do
  apply "$m"
done
# The resale rules (migs 20261014140000, 20261029090000: over the free tier
# and opted in) and last call (mig 20261029100000) postdate the marketplace
# fixtures (small events, no opt-in, a few seats): off for them.
# test_resale_min_capacity.sql, test_free_tier_resale.sql, test_last_call.sql
# and test_fixed_block.sql put the rules back for themselves.
$PSQL -c "INSERT INTO public.exos_platform_settings (key, value) VALUES ('free_tier_max_capacity', '-1'), ('resale_consent_required', 'false'), ('last_call_threshold', '0') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_exos_platform.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_p0.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fulfill_all_or_nothing.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_checkout_attribution.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_event_geo.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_promoters.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fan_referrals.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_voucher_tier.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_event_series_codes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_trial_run_fixes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_trial_run_fixes_2.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_presale_vouchers.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_edge_p1.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_p1_db_hardening.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_advisor_cleanup.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_promoter_commissions.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_referral_rewards.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_organizer_refunds.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_tables_guest_lists.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_abandoned_checkout.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_price_disclosure.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_refund_tables.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_accessible_tickets.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_stubhub_event_request.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_channel_event_links.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_marketplace_orders.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_channel_allocations.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_account_limit_flags.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_claim_any_account.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_seatgeek_orders.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_gametime_orders.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_gotickets_orders.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_vivid_orders.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_tevo_orders.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_marketplace_scarcity.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_guest_checkout.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_voucher_discounts_quotas.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_security_hardening.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_money_path_fixes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_door_hardening.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_marketplace_sale_note.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_marketplace_attention.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_marketplace_pricing.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_mcp.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_market_split.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_marketplace_fees.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_payout_ledger.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_mail_templates.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_wallet_passes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_calendar_feeds.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_pos_scaffold.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_rpc_hardening.sql"
# Buyer mistake simulations (mig 20261104100000; races: race_sim_buyer.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/sim_buyer.sql"
# Organizer mistake simulations (mig 20261104110000).
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/sim_organizer.sql"
# Mistake simulations (door staff and scanner phones; mig 20261104120000).
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/sim_door.sql"
# Replay: every pending migration again, in order, must be a no-op.
# It starts at 20260924215000, the first migration written to be re-run safe
# (review 2026-09-25). The older ones are applied above but not replayed: they
# are applied-once history in prod and will never be pending again, and 27 of
# them can't run twice as written (CREATE POLICY without DROP IF EXISTS, view
# columns reordered, return types changed since). Replaying the rest anyway
# is not a no-op either: it puts back older bodies of exos_mint_tickets,
# exos_claim_free_tickets, exos_issue_comp_batch, exos_queue_mail and
# exos_queue_ticket_issued, and a second exos_create_hold overload.
for m in \
         20260924215000_exos_fulfill_all_or_nothing \
         20260924223000_exos_checkout_attribution \
         20260924230000_exos_event_geo \
         20260924233000_exos_promoters \
         20260924234500_exos_fan_referrals \
         20260925000000_exos_voucher_unlocked_tier \
         20260925001000_exos_event_series_codes_fix \
         20260925003000_exos_trial_run_fixes \
         20260925010000_exos_trial_run_fixes_2 \
         20260925012000_exos_presale_vouchers \
         20260925013000_exos_scanner_no_buyer_email \
         20260925020000_exos_webhook_claim \
         20260925021000_exos_p1_db_hardening \
         20260926000000_exos_advisor_cleanup \
         20260926010000_exos_waitlist_signin_account_deletion \
         20260926020000_exos_promoter_commissions \
         20260926030000_exos_referral_rewards \
         20260926040000_exos_organizer_refunds \
         20260926050000_exos_tables_guest_lists \
         20260926060000_exos_abandoned_checkout \
         20260926070000_exos_price_disclosure \
         20260926080000_exos_refund_tables_fix \
         20260926090000_exos_accessible_tickets \
         20260926190000_exos_stubhub_event_request \
         20260926191000_exos_channel_event_links \
         20260926192000_exos_marketplace_orders \
         20260926193000_exos_channel_allocations \
         20260926194000_exos_listing_plan_account_flags \
         20260927010000_exos_claim_any_account \
         20260927020000_exos_seatgeek_channel_label \
         20260927030000_exos_marketplace_sync \
         20260927040000_exos_gametime_channel \
         20260927050000_exos_marketplace_standard \
         20260928010000_exos_marketplace_pools \
         20260928020000_exos_gotickets_channel \
         20260928030000_exos_vivid_channel \
         20260928040000_exos_marketplace_scarcity \
         20260928050000_exos_guest_checkout \
         20260928060000_exos_voucher_discounts_quota_editor \
         20260928070000_exos_tevo_channel \
         20260928080000_exos_tevo_inventory \
         20260929010000_exos_security_hardening \
         20260929020000_exos_pool_refill_order \
         20260929030000_exos_money_path_fixes \
         20260929040000_exos_door_hardening \
         20260929041000_exos_event_scanner_scope \
         20260929050000_exos_marketplace_sale_note \
         20260929051000_exos_marketplace_attention \
         20260929052000_exos_marketplace_pricing \
         20260929060000_exos_mcp \
         20260929061000_exos_market_split \
         20260929062000_exos_marketplace_fees \
         20260929070000_exos_payout_ledger \
         20260929071000_exos_mail_templates \
         20260929072000_exos_wallet_passes \
         20260929073000_exos_calendar_feeds \
         20260929074000_exos_pos_scaffold \
         20260929080000_exos_rpc_hardening \
         20260929120000_exos_event_store_content \
         20260929130000_exos_door_name_checkin \
         20260929131000_exos_checkout_records \
         20260929140000_exos_door_lists \
         20260929150000_exos_reschedule_refunds \
         20260930100000_exos_marketing_conversions \
         20260930101000_exos_audience_export \
         20260930102000_exos_oauth_google \
         20261001100000_exos_invoices_credit_notes \
         20261001101000_exos_disputes_reconciliation \
         20261005090000_exos_online_events \
         20261008090000_exos_door_delta_summary \
         20261008100000_exos_public_view_tax_grants \
         20261013090000_exos_door_imports \
         20261013100000_exos_eventbrite_sync \
         20261014090000_exos_auto_channel_split \
         20261014100000_exos_s4k_feed \
         20261014110000_exos_eventbrite_inventory \
         20261014120000_exos_eventbrite_checkins \
         20261014130000_exos_s4k_pools \
         20261014140000_exos_resale_min_capacity \
         20261014150000_exos_s4k_listings \
         20261014160000_exos_public_tier_available \
         20261015090000_exos_refund_asks \
         20261016090000_exos_org_integrations \
         20261016100000_exos_ticket_backends \
         20261016110000_exos_promo_links \
         20261016120000_exos_sms \
         20261016130000_exos_white_label \
         20261019090000_exos_channel_mirrors \
         20261019100000_exos_door_day_keys \
         20261019110000_exos_online_event_followups \
         20261019120000_exos_door_roster_wallet_delta \
         20261027080000_exos_public_tier_available_grant \
         20261027090000_exos_api_scopes \
         20261027100000_exos_fee_rules \
         20261029090000_exos_free_tier_resale_consent \
         20261029100000_exos_last_call \
         20261029120000_exos_weekly_channel_report \
         20261029130000_exos_discovery_publishing \
         20261029140000_exos_eventbrite_oauth \
         20261029150000_exos_posh_webhooks \
         20261029160000_exos_fixed_block \
         20261029170500_exos_event_import \
         20261030100000_exos_booking \
         20261030110000_exos_artists_feed \
         20261030120000_exos_sales_counts \
         20261030130000_exos_gift_cards_giving \
         20261030130500_exos_passes_memberships \
         20261030140000_exos_seating \
         20261030150000_exos_series_timed_entry \
         20261031100000_exos_offers \
         20261031100500_exos_settlements \
         20261031110000_exos_core_api \
         20261031120000_exos_fans \
         20261031130000_exos_partner_sales \
         20261031130500_exos_developer_platform \
         20261031210000_exos_matched_seats \
         20261031220000_exos_payments_paypal_cashapp_split \
         20261031230000_exos_group_chat \
         20261101000000_exos_integration \
         20261102100000_exos_membership_writes \
         20261102110000_exos_giving_writes \
         20261102120000_exos_finance_extras \
         20261102130000_exos_templates_inbound \
         20261102140000_exos_order_edits_recs \
         20261102150000_exos_promoter_wedge \
         20261102160000_exos_gaps_integration \
         20261104100000_exos_sim_buyer_fixes \
         20261104110000_exos_sim_organizer_fixes \
         20261104120000_exos_sim_door_fixes \
         20261104130000_exos_sim_partner_fixes \
         20261104150000_exos_posh_link_channel \
         20261104180000_exos_org_access \
         20261104190000_exos_commission_methods \
         20261104200000_exos_small_ops \
         20261105100000_exos_sim_decisions \
         20261105110000_exos_fan_api \
         20261105120000_exos_na_build \
         20261105130000_exos_promoter_events \
         20261105140000_exos_ig_checkout \
         20261105150000_exos_wave3_integration \
         20261105160000_exos_token_lineage \
         20261106100000_exos_dice_import \
         20261106110000_exos_checkout_questions \
         20261106120000_exos_shared_capacity \
         20261106130000_exos_price_steps \
         20261106140000_exos_buyer_geo_genre \
         20261107100000_exos_pos_walkup \
         20261107110000_exos_dice_gaps_6 \
         20261107120000_exos_partner_steps \
         20261107130000_exos_pos_terminal \
         20261108100000_exos_money_journal \
         20261108110000_exos_dice_leftovers \
         20261108120000_exos_group_pay \
         20261108130000_exos_claim_alias_fix \
         20261109100000_exos_org_audit \
         20261109110000_exos_security_hygiene \
         20261110100000_exos_journal_complete \
         20261110110000_exos_group_pay_2 \
         20261110120000_exos_leftovers_9 \
         20261111100000_exos_e2e_fixes \
         20261111110000_exos_neighborhoods \
         20261111120000_exos_group_pay_off \
         20261111130000_exos_journal_payouts_tax \
         20261111140000_exos_api_leftovers \
         20261112100000_exos_follower_fixes \
         20261113110000_exos_fair_day; do
  $PSQL -f "$MIG/$m.sql"
done
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_replay_idempotent.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_wallet_passes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_edge_p1.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_rpc_hardening.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_event_store_content.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_door_name_checkin.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_checkout_records.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_door_lists.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_reschedule_refunds.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_marketing_conversions.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_audience_export.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_oauth_google.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_invoices_credit_notes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_disputes_reconciliation.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_online_events.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_door_delta_summary.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_door_imports.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_eventbrite_sync.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_auto_channel_split.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_s4k_feed.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_eventbrite_inventory.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_eventbrite_checkins.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_s4k_pools.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_resale_min_capacity.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_s4k_listings.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_refund_asks.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_integrations_backends.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_promo_links.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_sms.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_white_label.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_channel_mirrors.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_door_day_keys.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_online_event_followups.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_api_scopes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fee_rules.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_public_tier_available.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_free_tier_resale.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_last_call.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_discovery_publishing.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_posh_webhooks.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fixed_block.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_weekly_channel_report.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_eventbrite_oauth.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_event_import.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_sales_counts.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_seating.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_booking.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_series_timed_entry.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_artists_feed.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_gift_cards_giving.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_passes_memberships.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_offers_settlements.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_core_api.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fans.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_partner_sales.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_developer_platform.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_matched_seats.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_paypal_payments.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_group_chat.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_integration.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_membership_writes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_giving_writes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_finance_extras.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_templates_inbound.sql"
# claude/exos-gap-orders
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_order_edits_recs.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_promoter_wedge.sql"
# gaps integration (mig 20261102160000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_gaps_integration.sql"
# Mistake simulations: partner API + partner sales (mig 20261104130000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/sim_partner.sql"
# Posh third-party link discovery channel (mig 20261104150000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_posh_link_channel.sql"
# Org API permissions, venue requests, partner presale (mig 20261104180000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_org_access.sql"
# claude/exos-commission-methods: four ways to fund promoter commissions (mig 20261104190000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_commission_methods.sql"
# Partner caps, invite approval, drawer recount (mig 20261104200000; race: race_sim_partner.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_small_ops.sql"
# Fan API: /v1/me, account tokens, the org writes of the gap list (mig 20261105110000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fan_api.sql"
# claude/exos-na-build: printed tickets, box-office memberships, team switch, staff shifts, Tixel, retag (mig 20261105120000; race: race_print_codes.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_na_build.sql"
# Promoter-run events: org type, location modes, secret address reveal (mig 20261105130000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_promoter_events.sql"
# Instagram / Facebook in-app browser checkout: where checkouts start, the report (mig 20261105140000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_ig_checkout.sql"
# Wave 3 integration (mig 20261105150000): every #85/#87/#88/#89 patch survives the replay; account tokens and X-Exos-Org; closed types sold out in public discovery
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_wave3_integration.sql"
# Token lineage (mig 20261105160000): API-minted tokens record their parent, die with it, always expire, can't mint
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_token_lineage.sql"
# claude/exos-dice-import: import from DICE (mig 20261106100000): token never readable, idempotent re-import, returns block admission, consent only with optInPartners, cross-org
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_dice_import.sql"
# claude/exos-checkout-questions: checkout questions, answers per order / ticket, the door, RSVP, API cores, TS/SQL parity (mig 20261106110000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_checkout_questions.sql"
# claude/exos-capacity-pricing: shared capacity (DICE TicketPool, mig 20261106120000; race: race_shared_capacity.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -v fixtures="$DIR/fixtures" -f "$DIR/test_shared_capacity.sql"
# claude/exos-capacity-pricing: price steps (DICE PriceTier, mig 20261106130000; race: race_price_steps.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -v fixtures="$DIR/fixtures" -f "$DIR/test_price_steps.sql"
# Buyer location + genre filter (mig 20261106140000): order locations (RLS, report sums, account deletion), genres in the organizer and public discovery APIs
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_buyer_geo_genre.sql"
# claude/exos-pos-walkup: walk-up sales at the door, void / refund, paid-outs, settlement (mig 20261107100000; race: race_pos_walkup.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_pos_walkup.sql"
# claude/exos-pos-terminal: card at the door through Stripe Terminal: locations, readers, tokens, card sale states, webhook idempotency, refunds, cross-org (mig 20261107130000; race: race_pos_terminal.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_pos_terminal.sql"
# claude/exos-dice-gaps-6 (mig 20261107110000): fee-change log (append-only, refunds, RLS), add-on entry codes at their own lists (online + offline), conditional checkout questions (race: race_dice_gaps_6.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_dice_gaps_6.sql"
# claude/exos-partner-steps: partner + organizer reservations lock a price step; one pool lock order on complete (mig 20261107120000; race: race_partner_steps.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_partner_steps.sql"
# claude/exos-dice-leftovers (mig 20261108110000): walk-up questions (required, logged skip), POST fee adjustments (API core), undo an add-on scan (online + offline merge), add-on wallet codes at the door (race: race_dice_leftovers.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_dice_leftovers.sql"
# claude/exos-money-journal: double-entry journal per org, trial balance, sales tax by jurisdiction, $0 orders for free claims and comps (mig 20261108100000; race: race_money_journal.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_money_journal.sql"
# claude/exos-journal-2: the journal completed: POS card tenders and card refunds, gift cards (sale, redemption, refund, void), instant payouts and PayPal remittances, the drawer float and count variance; whole-DB trial balance (mig 20261110100000; race: race_money_journal.sh races 5-7, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_journal_complete.sql"
# claude/exos-journal-3: Stripe's scheduled payouts from the connected account (record, post, reverse, idempotent, scoped to the org's own account), the sales tax report read from the journal (agrees per org, currency, event and period), the Exos fee owed on a gift card part handed back (mig 20261111130000; race: race_journal_payouts.sh, CI)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_journal_payouts_tax.sql"
# claude/exos-group-pay: group buy v2, each friend pays their own seat in a 30-minute window: holds, deadline release, cover the rest, per-seat orders, cross-group / cross-org tokens (mig 20261108120000; race: race_group_pay.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_group_pay.sql"
# claude/exos-group-pay-off (mig 20261111120000): group pay v2 paused by the operator 2026-11-09: off by default (platform setting group_pay_enabled), the admin-only audited setter, every entry point refuses (start / claim / checkout context XGOFF, seat page NULL), an existing group stays readable; the suites above turn it on for themselves
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_group_pay_off.sql"
# claude/exos-harness-full: transfer claims through prod's exos_claim_transfer body (mig 20261108130000: the proof check's alias clashed with its row variable t)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_claim_alias_fix.sql"
# claude/exos-org-audit: the org audit log (mig 20261109100000): append-only, RLS, actors (user, API key, OAuth app, service), masking, cross-org, export.run (race: race_org_audit.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_org_audit.sql"
# claude/exos-hygiene: advisor sweep 2026-11-09: probe table, anon off exos sequences and two helpers, auth.* wrapped in exos policies (same access), parked guest tickets in matched seats, seat view ids (mig 20261109110000)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_security_hygiene.sql"
# claude/exos-leftovers-9 (mig 20261110120000): partner / organizer reservations take checkout answers (required for partners, conditional, cross-org), API undo of an add-on scan, the event report's changes since publish
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_leftovers_9.sql"
# claude/exos-neighborhoods (mig 20261111110000): neighborhood pages (matching, window, hidden / noindex left out, admin-only count), follower "new event" mail (consent, once per event + follower, 24-hour limit + batching, cross-org), follower list + export, unfollow by token (race: race_follower_mail.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_neighborhoods.sql"
# claude/exos-follower-fixes (mig 20261112100000): a publish with 5,000 followers under statement_timeout 2s (notices only, one INSERT; the digest job mails, oldest first), the same for exos_announce_to_followers, the follow throttle (30 a minute, 300 a day), no address in the follower list, exos_audit_export 200 a day per org, unconfirmed addresses skipped (race: race_follower_mail.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_follower_fixes.sql"
# claude/exos-fair-day (mig 20261113110000): fair days: a day list admits once per day (several gates share the day), a multi-day pass on each of its days, the any-day pass on one day only (max_entry_days), re-entry presets, the lot list scans only parking / camping codes, offline replay and by name follow, the roster carries day lists, the fair setup preset (owner / manager only, one transaction, once), the per-gate throughput view (buckets, in-park now, refusals; cross-org refused) (race: race_fair_day.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_fair_day.sql"
# claude/exos-api-leftovers (mig 20261111140000): reservation updates replace checkout answers while open (partners' required ones required, audit, cross-partner / org), partner order reads carry answers (hidden left out), add-on wallet reissue (holder only, door refuses old codes, 5 a day, RLS) (race: race_api_leftovers.sh, by hand)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_api_leftovers.sql"
# claude/exos-e2e-sim (wave 10): one org driven end to end across waves 1-9 (setup, sales, after-sale), the invariants after every step (journal balanced, sold = live tickets, pools, an order record per ticket, journal = settlement, one audit row per action, no PII, cross-org RLS); mig 20261111100000 (one audit row per price-step change). Races: race_full.sh (CI, after this script)
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/sim_full.sql"
