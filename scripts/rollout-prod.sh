#!/usr/bin/env bash
# Prod rollout for the Exos build on PR #79 / #80: the remaining migrations, then
# every edge function. Run from the repo root on branch claude/exos-gaps.
#
#   DB_URL='postgresql://postgres.<ref>:<password>@<pooler-host>:5432/postgres' \
#   SUPABASE_ACCESS_TOKEN='sbp_…' \
#   bash scripts/rollout-prod.sh migrations      # step 1
#   bash scripts/rollout-prod.sh functions       # step 2 (after step 1 is clean)
#
# DB_URL: Supabase → the project's "Connect" button → Connection String → "Session pooler".
# SUPABASE_ACCESS_TOKEN: supabase.com → Account → Access Tokens. Uses the supabase CLI if
# installed, else `npx supabase@3.0.0` (2.x and 3.x flags both handled).
#
# No DB_URL (e.g. a host that can reach api.supabase.com but not Postgres on 5432)?
# `migrations` then runs over HTTPS through the Management API
# (POST /v1/projects/<ref>/database/query) with SUPABASE_ACCESS_TOKEN alone: each
# file and its history row are sent as ONE `BEGIN; … COMMIT;` request, so a
# failing file commits nothing. Needs curl and jq.
#
# Why not `supabase db push`: prod's history records each migration under the time it
# was applied, not its file timestamp, so db push would try to re-run ~200 Exos files.
# This script applies only the listed files, each in ONE transaction together with its
# history row, skips any already recorded (by name), and stops at the first error.
# 20261027090000_exos_api_scopes was applied on 2026-11-04 (version 20261104184729).
#
# After the rollout: run scripts/verify-prod.sh (read-only) with the same DB_URL
# (or, without one, SUPABASE_ACCESS_TOKEN: its db checks then use the Management
# API too) plus SUPABASE_URL and SUPABASE_ANON_KEY.
# Applied in full: 2026-11-05 through 20261106140000, 2026-11-06 wave 6 (20261107*) (see KANBAN "Prod state"). A text patch that
# stops this script ("expected N match(es) ... found 0") means prod's function
# body differs from the repo's: see supabase/README.md, migration rule 4. It checks that every migration above is
# recorded, their objects exist, anon grants and RLS, the exos crons, that each
# edge function is deployed and boots, and the platform settings rows. Exit 0 = no FAIL.
#   bash scripts/verify-prod.sh all      # or: db | http
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
  20261104200000_exos_small_ops
  20261105100000_exos_sim_decisions
  20261105110000_exos_fan_api       # exos-api's /v1/me, account tokens: apply before deploying exos-api
  20261105120000_exos_na_build      # exos-api's X-Exos-Org calls exos_api_token_auth_org: apply before deploying exos-api
  20261105130000_exos_promoter_events
  20261105140000_exos_ig_checkout
  20261105150000_exos_wave3_integration
  20261105160000_exos_token_lineage
  20261106100000_exos_dice_import   # claude/exos-dice-import; its hourly cron is created inactive
  20261106110000_exos_checkout_questions
  20261106120000_exos_shared_capacity
  20261106130000_exos_price_steps
  20261106140000_exos_buyer_geo_genre
  20261107100000_exos_pos_walkup      # claude/exos-pos-walkup; no cron
  20261107110000_exos_dice_gaps_6  # claude/exos-dice-gaps-6: fee log, add-on entry codes, conditional questions
  20261107120000_exos_partner_steps
  20261107130000_exos_pos_terminal    # claude/exos-pos-terminal; no cron; card stays off until EXOS_POS_CARD=on
  20261108100000_exos_money_journal   # claude/exos-money-journal; no cron; backfills the journal at apply
  20261108110000_exos_dice_leftovers  # claude/exos-dice-leftovers: walk-up questions, POST fee adjustments, add-on undo, add-on wallet codes; no cron
  20261108120000_exos_group_pay       # claude/exos-group-pay; no cron (the existing exos_expire_holds sweep); patches exos_fulfill_checkout
  20261108130000_exos_claim_alias_fix  # claude/exos-harness-full: transfer claims fail in prod (t.order_ref ambiguous); conditional patch, no cron
  20261109100000_exos_org_audit       # claude/exos-org-audit: org audit log; 34 marker patches (2 conditional: exos_set_org_comp_budget, exos_void_ticket); no cron; apply before deploying exos-api (audit:read)
  20261109110000_exos_security_hygiene  # claude/exos-hygiene: advisor sweep (probe table, sequence + helper grants, RLS initplan wraps, matched-seats parked key, seat view ids); no cron
  20261110100000_exos_journal_complete  # claude/exos-journal-2: POS card, gift cards, payouts, drawer in the journal; no cron; backfills at apply
  20261110110000_exos_group_pay_2     # claude/exos-group-pay-2: group pay on timed / price-step types, seat labels, friends' open pages listed for expiry (exos-reconcile-checkouts); no cron; deploy exos-checkout + exos-reconcile-checkouts after
  20261110120000_exos_leftovers_9     # claude/exos-leftovers-9: reservation answers (2 patches on _exos_partner_reserve), API add-on undo (2 patches on exos_api_write), event audit summary; no cron; apply before deploying exos-api
  20261111100000_exos_e2e_fixes      # claude/exos-e2e-sim: one audit row per price-step change (patches _exos_tg_audit_row, exos_set_price_steps, _exos_api_price_steps_set); no cron, no deploy needed
  20261111110000_exos_neighborhoods  # claude/exos-neighborhoods: neighborhood pages (anon RPCs), follower new-event mail (trigger on exos_events, queued only), follower list; cron exos-follower-digests-hourly created INACTIVE; redefines exos_announce_to_followers
  20261111120000_exos_group_pay_off  # claude/exos-group-pay-off: group pay v2 paused (operator 2026-11-09): switch group_pay_enabled (off), 4 patches (start / claim / ctx refuse XGOFF, seat view NULL); no cron; leave EXOS_GROUP_PAY unset on exos-checkout
  20261111130000_exos_journal_payouts_tax  # claude/exos-journal-3: Stripe scheduled payouts table + journal posting, tax report read from the journal, gift card owed-fee hand-back; 2 marker patches (exos_journal_post_gift_card, _exos_journal_backfill); no cron; backfills at apply; deploy exos-reconcile-stripe after
  20261111140000_exos_api_leftovers  # claude/exos-api-leftovers: reservation update answers (patch on _exos_partner_reservation_update), partner order answers (patches on _exos_partner_orders / _exos_partner_order), add-on wallet reissue (+ exos_my_addon_passes epoch); no cron; apply before deploying exos-api + exos-wallet
  20261112100000_exos_follower_fixes  # claude/exos-follower-fixes: publish records follower notices only (one INSERT), the digest job mails; follow throttle (patch on exos_follow_org), follower list without email, exos_audit_export 200 a day (patch), confirmed email only; no cron change; ship the SPA after
  20261113100000_exos_kiosk          # claude/exos-kiosk: kiosk mode (2 tables, channel on exos_pos_orders + trigger); 3 marker patches (_exos_pos_order_json, _exos_pos_walkup_complete, exos_pos_settlement_summary); no cron; deploy exos-pos + ship the SPA after; sells only with EXOS_POS_CARD=on
  20261113110000_exos_fair_day  # claude/exos-fair-day: fair days (exos_checkin_lists.entry_day, exos_ticket_tiers.max_entry_days; patches on exos_check_in_ticket 10-arg, exos_door_checkin_by_name 8-arg, exos_check_in_offline 10-arg, exos_event_door_roster), exos_fair_setup, exos_door_throughput, 4 indexes; no cron; ship the SPA after
  20261113120000_exos_attendance_report  # claude/exos-attendance-report: attendance report (postal rollup, pacing; exos_event_attendance + _exos_api_attendance), XLSX export kinds (2 patches on exos_audit_export); no table, no cron; apply before deploying exos-api; ship the SPA after
)

# Functions that keep JWT verification; every other function deploys with --no-verify-jwt
# (they check auth themselves, or are called by Stripe, cron, Eventbrite or public feeds).
VERIFY_JWT=(exos-checkout exos-refund exos-connect-onboard exos-pos exos-geocode)
FIRST=(stripe-webhook exos-checkout exos-refund exos-reconcile-checkouts exos-reconcile-stripe)

API="https://api.supabase.com/v1/projects/$REF/database/query"

# Run SQL through the Management API; prints the error body and fails on an error.
api_sql() {
  local out code
  out=$(jq -Rs '{query: .}' | curl -sS -X POST "$API" \
          -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
          --data-binary @- -w $'\n%{http_code}')
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  [[ "$code" == 2* ]] || { echo "Management API error (HTTP $code): $out" >&2; return 1; }
  printf '%s' "$out"
}

# One query, one column per row, like psql -At.
q() {
  if [ -n "${DB_URL:-}" ]; then psql "$DB_URL" -X -q -At -v ON_ERROR_STOP=1 -c "$1"
  else printf '%s' "$1" | api_sql | jq -r '.[] | [.[] | tostring] | join("|")'; fi
}

migrations() {
  if [ -z "${DB_URL:-}" ]; then
    : "${SUPABASE_ACCESS_TOKEN:?set DB_URL, or SUPABASE_ACCESS_TOKEN for the Management API}"
    command -v jq >/dev/null || { echo "install jq first"; exit 1; }
    echo "no DB_URL: applying through the Management API ($API)"
  fi
  echo "exos crons before:"; q "select jobname||' '||active from cron.job where jobname like 'exos%' order by 1"
  # The operator may have turned some crons on (2026-11-04: 14 of 16). Remember
  # which, so the check below only fails on a cron THIS rollout made active.
  local before_active
  before_active=$(q "select coalesce(string_agg(quote_literal(jobname), ',' order by jobname), '''''') from cron.job where jobname like 'exos%' and active") \
    || { echo "could not read cron.job: stopping"; exit 1; }
  for m in "${MIGRATIONS[@]}"; do
    f="$MIG/$m.sql"; [ -f "$f" ] || { echo "missing $f"; exit 1; }
    # A failed lookup must stop the run, never read as "already recorded".
    local seen used
    seen=$(q "select count(*) from supabase_migrations.schema_migrations where name in ('$m','${m#*_}')") \
      || { echo "could not read the migration history: stopping before $m"; exit 1; }
    case "$seen" in
      0) ;;
      [1-9]*) echo "skip  $m (already recorded)"; continue ;;
      *) echo "unexpected history answer for $m: '$seen': stopping"; exit 1 ;;
    esac
    v="${m%%_*}"
    used=$(q "select count(*) from supabase_migrations.schema_migrations where version = '$v'") \
      || { echo "could not read the migration history: stopping before $m"; exit 1; }
    [ "$used" = 0 ] || { echo "version $v already used by another migration (or unreadable: '$used'): stopping"; exit 1; }
    echo "apply $m"
    # The file and its history row commit together, or neither does.
    if [ -n "${DB_URL:-}" ]; then
      psql "$DB_URL" -X -q -1 -v ON_ERROR_STOP=1 -f "$f" \
        -c "insert into supabase_migrations.schema_migrations(version, name) values ('$v', '$m')"
    else
      { printf 'BEGIN;\n'; cat "$f";
        printf '\n;\ninsert into supabase_migrations.schema_migrations(version, name) values (%s, %s);\nCOMMIT;\n' "'$v'" "'$m'"
      } | api_sql >/dev/null || { echo "FAILED on $m (nothing from it was committed)"; exit 1; }
    fi
  done
  echo "exos crons after:"; q "select jobname||' '||active from cron.job where jobname like 'exos%' order by 1"
  # Every cron these migrations create starts inactive; any newly active one is a bug.
  newly=$(q "select coalesce(string_agg(jobname, ' '), '') from cron.job where jobname like 'exos%' and active and jobname not in ($before_active)")
  [ -z "$newly" ] || { echo "WARNING: cron(s) made active by this rollout: $newly"; exit 1; }
  echo "migrations done"
}

functions() {
  : "${SUPABASE_ACCESS_TOKEN:?set SUPABASE_ACCESS_TOKEN}"
  # The installed CLI, else a pinned one through npx (no global install needed).
  local sb=(supabase) target=()
  command -v supabase >/dev/null || sb=(npx --yes supabase@3.0.0)
  "${sb[@]}" --version >/dev/null 2>&1 || { echo "no supabase CLI (and npx could not fetch one)"; exit 1; }
  # CLI 3.x targets a project with --remote=<ref> and needs --yes for hosted changes;
  # 2.x takes --project-ref. Never --prune: it deletes deployed functions not in this repo.
  if "${sb[@]}" functions deploy --help 2>&1 | grep -q -- '--remote'; then target=(--remote="$REF" --yes)
  else target=(--project-ref "$REF"); fi
  echo "supabase CLI: $("${sb[@]}" --version 2>&1 | tail -1) (${target[*]})"
  local all=() rest=()
  for d in supabase/functions/*/; do n=$(basename "$d"); [ "$n" = _shared ] || all+=("$n"); done
  for n in "${all[@]}"; do [[ " ${FIRST[*]} " == *" $n "* ]] || rest+=("$n"); done
  for n in "${FIRST[@]}" "${rest[@]}"; do
    flag=--no-verify-jwt; [[ " ${VERIFY_JWT[*]} " == *" $n "* ]] && flag=
    echo "deploy $n ${flag:-(verify jwt)}"
    "${sb[@]}" functions deploy "$n" "${target[@]}" --use-api $flag
  done
  echo "functions done"
}

case "${1:-}" in
  migrations) migrations ;;
  functions) functions ;;
  *) echo "usage: $0 migrations|functions"; exit 2 ;;
esac
