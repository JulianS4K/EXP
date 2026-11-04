#!/usr/bin/env bash
# Prod rollout for the Exos build on PR #79 / #80: the remaining migrations, then
# every edge function. Run from the repo root on branch claude/exos-gaps.
#
#   DB_URL='postgresql://postgres.<ref>:<password>@<pooler-host>:5432/postgres' \
#   SUPABASE_ACCESS_TOKEN='sbp_…' \
#   bash scripts/rollout-prod.sh migrations      # step 1
#   bash scripts/rollout-prod.sh functions       # step 2 (after step 1 is clean)
#
# DB_URL: Supabase → Project Settings → Database → Connection string → "Session pooler".
# SUPABASE_ACCESS_TOKEN: supabase.com → Account → Access Tokens. Needs the supabase CLI.
#
# Why not `supabase db push`: prod's history records each migration under the time it
# was applied, not its file timestamp, so db push would try to re-run ~200 Exos files.
# This script applies only the listed files, each in ONE transaction together with its
# history row, skips any already recorded (by name), and stops at the first error.
# 20261027090000_exos_api_scopes was applied on 2026-11-04 (version 20261104184729).
set -euo pipefail
cd "$(dirname "$0")/.."
REF=hzrizjeaxlqcxfrtczpq
MIG=supabase/migrations

MIGRATIONS=(
  20261027100000_exos_fee_rules
  20261029090000_exos_free_tier_resale_consent
  20261029100000_exos_last_call
  20261029120000_exos_weekly_channel_report
  20261029130000_exos_discovery_publishing
  20261029140000_exos_eventbrite_oauth
  20261029150000_exos_posh_webhooks
  20261029160000_exos_fixed_block
  20261029170500_exos_event_import
  20261030100000_exos_booking
  20261030110000_exos_artists_feed
  20261030120000_exos_sales_counts
  20261030130000_exos_gift_cards_giving
  20261030130500_exos_passes_memberships
  20261030140000_exos_seating
  20261030150000_exos_series_timed_entry
  20261031100000_exos_offers
  20261031100500_exos_settlements
  20261031110000_exos_core_api
  20261031120000_exos_fans
  20261031130000_exos_partner_sales
  20261031130500_exos_developer_platform
  20261031210000_exos_matched_seats
  20261031220000_exos_payments_paypal_cashapp_split
  20261031230000_exos_group_chat
  20261101000000_exos_integration
  20261102100000_exos_membership_writes
  20261102110000_exos_giving_writes
  20261102120000_exos_finance_extras
  20261102130000_exos_templates_inbound
  20261102140000_exos_order_edits_recs
  20261102150000_exos_promoter_wedge
  20261102160000_exos_gaps_integration
  20261104100000_exos_sim_buyer_fixes
  20261104110000_exos_sim_organizer_fixes
  20261104120000_exos_sim_door_fixes
  20261104130000_exos_sim_partner_fixes
  20261104150000_exos_posh_link_channel
  20261104180000_exos_org_access    # exos-api / exos-mcp call exos_api_key_auth: apply before deploying them
  20261104190000_exos_commission_methods
)

# Functions that keep JWT verification; every other function deploys with --no-verify-jwt
# (they check auth themselves, or are called by Stripe, cron, Eventbrite or public feeds).
VERIFY_JWT=(exos-checkout exos-refund exos-connect-onboard exos-pos exos-geocode)
FIRST=(stripe-webhook exos-checkout exos-refund exos-reconcile-checkouts exos-reconcile-stripe)

q() { psql "$DB_URL" -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }

migrations() {
  : "${DB_URL:?set DB_URL}"
  echo "exos crons before:"; q "select jobname||' '||active from cron.job where jobname like 'exos%' order by 1"
  for m in "${MIGRATIONS[@]}"; do
    f="$MIG/$m.sql"; [ -f "$f" ] || { echo "missing $f"; exit 1; }
    if [ "$(q "select count(*) from supabase_migrations.schema_migrations where name in ('$m','${m#*_}')")" != 0 ]; then
      echo "skip  $m (already recorded)"; continue
    fi
    v="${m%%_*}"
    if [ "$(q "select count(*) from supabase_migrations.schema_migrations where version = '$v'")" != 0 ]; then
      echo "version $v already used by another migration: stopping"; exit 1
    fi
    echo "apply $m"
    # -1: the file and its history row commit together, or neither does.
    psql "$DB_URL" -X -q -1 -v ON_ERROR_STOP=1 -f "$f" \
      -c "insert into supabase_migrations.schema_migrations(version, name) values ('$v', '$m')"
  done
  echo "exos crons after (every row must say f):"; q "select jobname||' '||active from cron.job where jobname like 'exos%' order by 1"
  active=$(q "select count(*) from cron.job where jobname like 'exos%' and active")
  [ "$active" = 0 ] || { echo "WARNING: $active exos cron(s) active"; exit 1; }
  echo "migrations done"
}

functions() {
  : "${SUPABASE_ACCESS_TOKEN:?set SUPABASE_ACCESS_TOKEN}"
  command -v supabase >/dev/null || { echo "install the supabase CLI first"; exit 1; }
  local all=() rest=()
  for d in supabase/functions/*/; do n=$(basename "$d"); [ "$n" = _shared ] || all+=("$n"); done
  for n in "${all[@]}"; do [[ " ${FIRST[*]} " == *" $n "* ]] || rest+=("$n"); done
  for n in "${FIRST[@]}" "${rest[@]}"; do
    flag=--no-verify-jwt; [[ " ${VERIFY_JWT[*]} " == *" $n "* ]] && flag=
    echo "deploy $n ${flag:-(verify jwt)}"
    supabase functions deploy "$n" --project-ref "$REF" --use-api $flag
  done
  echo "functions done"
}

case "${1:-}" in
  migrations) migrations ;;
  functions) functions ;;
  *) echo "usage: $0 migrations|functions"; exit 2 ;;
esac
