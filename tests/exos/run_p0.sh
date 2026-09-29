#!/usr/bin/env bash
# P0 regression run (2026-09-24): the platform chain from run.sh PLUS the real
# checkout/fulfillment layer (cart holds, quotas, payment ledger, tier-1 wiring)
# and the P0 migrations, in chronological order. Runs the existing platform
# suite (must still pass) and then test_p0.sql.
#   bash tests/exos/run_p0.sh <db>
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; P="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR/../../supabase/migrations"
psql -h "$H" -p "$P" -U "$U" -q -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
PSQL="psql -h $H -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -q"
$PSQL -f "$DIR/prereq.sql"
for m in \
  20260523230000_exos_issue_to_email 20260605132500_exos_claim_free_tickets \
  20260616180000_exos_waitlist 20260616190000_exos_addons 20260616200000_exos_public_api_webhooks \
  20260616210000_exos_vouchers 20260616220000_exos_waitlist_autoassign 20260616230000_exos_tax \
  20260616240000_exos_invoicing 20260616250000_exos_voucher_bypass_fulfill \
  20260702120000_exos_checkin_harden_doors_gate 20260702121000_exos_transfer_secret_leak_fix \
  20260702122000_exos_voucher_singleuse_and_limit_atomic \
  20260702123000_exos_cart_holds 20260702123030_exos_quotas 20260702123100_exos_payment_ledger \
  20260702123200_exos_tier1_wiring \
  20260702144537_exos_checkin_test_window_autoexpiry 20260702144607_exos_waitlist_idor_fix \
  20260911050000_exos_invoice_counters_rls 20260911051000_exos_event_reminders \
  20260911060000_exos_ticket_attendee_name 20260911070000_exos_event_reminders_hardening \
  20260911130000_exos_event_analytics 20260911131000_exos_rsvp_release \
  20260911132000_exos_comp_batch 20260911133000_exos_event_series \
  20260924205115_exos_p0_refund_ledger 20260924205508_exos_p0_voucher_per_ticket \
  20260924205916_exos_p0_hold_caps 20260924210103_exos_p0_quota_aware_mints \
  20260703122000_exos_tier_price_schedule 20260924211840_exos_all_in_price_tax \
  20260924215000_exos_fulfill_all_or_nothing 20260924223000_exos_checkout_attribution \
  20260924230000_exos_event_geo 20260924233000_exos_promoters \
  20260924234500_exos_fan_referrals 20260925000000_exos_voucher_unlocked_tier \
  20260925001000_exos_event_series_codes_fix 20260925003000_exos_trial_run_fixes \
  20260925010000_exos_trial_run_fixes_2 20260925012000_exos_presale_vouchers \
  20260925013000_exos_scanner_no_buyer_email 20260925020000_exos_webhook_claim \
  20260925021000_exos_p1_db_hardening 20260926000000_exos_advisor_cleanup \
  20260926010000_exos_waitlist_signin_account_deletion \
  20260926020000_exos_promoter_commissions 20260926030000_exos_referral_rewards \
  20260926040000_exos_organizer_refunds 20260926050000_exos_tables_guest_lists \
  20260926060000_exos_abandoned_checkout 20260926070000_exos_price_disclosure \
  20260926080000_exos_refund_tables_fix 20260926090000_exos_accessible_tickets; do
  $PSQL -f "$MIG/$m.sql"
done
# Distribution queue + StubHub event requests (the stub needs the phase-1 columns first).
$PSQL -f "$DIR/prereq_distribution.sql"
# Prod's mail RPCs that mig 20260929080000 patches (they predate this chain).
$PSQL -f "$DIR/prereq_rpc_hardening.sql"
for m in 20260523190000_exos_distribution 20260926190000_exos_stubhub_event_request \
         20260926191000_exos_channel_event_links 20260926192000_exos_marketplace_orders \
         20260926193000_exos_channel_allocations 20260926194000_exos_listing_plan_account_flags \
         20260927010000_exos_claim_any_account \
         20260927020000_exos_seatgeek_channel_label 20260927030000_exos_marketplace_sync \
         20260927040000_exos_gametime_channel 20260927050000_exos_marketplace_standard \
         20260928010000_exos_marketplace_pools 20260928020000_exos_gotickets_channel \
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
         20260929131000_exos_checkout_records; do
  $PSQL -f "$MIG/$m.sql"
done
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
# Replay: every pending migration again, in order, must be a no-op.
for m in 20260924215000_exos_fulfill_all_or_nothing 20260924223000_exos_checkout_attribution \
  20260924230000_exos_event_geo 20260924233000_exos_promoters 20260924234500_exos_fan_referrals \
  20260925000000_exos_voucher_unlocked_tier 20260925001000_exos_event_series_codes_fix \
  20260925003000_exos_trial_run_fixes 20260925010000_exos_trial_run_fixes_2 \
  20260925012000_exos_presale_vouchers 20260925013000_exos_scanner_no_buyer_email \
  20260925020000_exos_webhook_claim 20260925021000_exos_p1_db_hardening \
  20260926000000_exos_advisor_cleanup \
  20260926010000_exos_waitlist_signin_account_deletion \
  20260926020000_exos_promoter_commissions 20260926030000_exos_referral_rewards \
  20260926040000_exos_organizer_refunds 20260926050000_exos_tables_guest_lists \
  20260926060000_exos_abandoned_checkout 20260926070000_exos_price_disclosure \
  20260926080000_exos_refund_tables_fix 20260926090000_exos_accessible_tickets \
  20260926190000_exos_stubhub_event_request 20260926191000_exos_channel_event_links \
  20260926192000_exos_marketplace_orders 20260926193000_exos_channel_allocations \
  20260926194000_exos_listing_plan_account_flags 20260927010000_exos_claim_any_account \
         20260927020000_exos_seatgeek_channel_label 20260927030000_exos_marketplace_sync \
         20260927040000_exos_gametime_channel 20260927050000_exos_marketplace_standard \
         20260928010000_exos_marketplace_pools 20260928020000_exos_gotickets_channel \
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
         20260929131000_exos_checkout_records; do
  $PSQL -f "$MIG/$m.sql"
done
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_replay_idempotent.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_wallet_passes.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_edge_p1.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_rpc_hardening.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_event_store_content.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_door_name_checkin.sql"
psql -h "$H" -p "$P" -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -f "$DIR/test_checkout_records.sql"
