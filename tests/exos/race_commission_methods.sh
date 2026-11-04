#!/usr/bin/env bash
# Concurrency checks for commission methods (mig 20261104190000): real
# sessions racing. Not in CI (timing-based); run by hand against a DB built by
# run_p0.sh:
#   bash tests/exos/race_commission_methods.sh exos_p0_test
# Expect: race 1 two planners on one split order plan it once (1 organizer +
# 1 promoter transfer); race 2 two sends on one transfer: one claims, the other
# is busy; race 3 two planners on one promoter's fee sales make one transfer.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=0d0e0000-0000-0000-0000-000000000001; A=0d0e0000-0000-0000-0000-0000000000a1; B=0d0e0000-0000-0000-0000-0000000000a5
E=0d0e0000-0000-0000-0000-0000000000e1; F=0d0e0000-0000-0000-0000-0000000000e3
T=0d0e0000-0000-0000-0000-0000000000d1; TF=0d0e0000-0000-0000-0000-0000000000d3
cleanup() {
  $P -c "DELETE FROM exos_commission_netting WHERE org_id='$O'; DELETE FROM exos_commission_transfers WHERE org_id='$O';
         DELETE FROM exos_promoter_commissions WHERE org_id='$O'; DELETE FROM exos_promoter_payouts WHERE org_id='$O';
         DELETE FROM exos_order_payments WHERE org_id='$O'; DELETE FROM exos_tickets WHERE org_id='$O';
         DELETE FROM exos_checkout_sessions WHERE org_id='$O'; DELETE FROM exos_promoter_stripe_accounts WHERE org_id='$O';
         DELETE FROM exos_promoters WHERE org_id='$O'; DELETE FROM exos_event_commission_settings WHERE org_id='$O';
         DELETE FROM exos_org_commission_settings WHERE org_id='$O'; DELETE FROM exos_commission_method_changes WHERE org_id='$O';
         DELETE FROM exos_ticket_tiers WHERE event_id IN ('$E','$F'); DELETE FROM exos_events WHERE org_id='$O';
         DELETE FROM exos_org_secrets WHERE org_id='$O'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id IN ('$A','$B');" >/dev/null 2>&1 || true
}
$P -c "CREATE TABLE IF NOT EXISTS public.exos_org_secrets (org_id uuid PRIMARY KEY, payments jsonb, updated_at timestamptz NOT NULL DEFAULT now());" >/dev/null
cleanup
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-cm.example',now()), ('$B','buyer@race-cm.example',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race CM','race-cm','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_org_secrets(org_id,payments) VALUES ('$O','{\"connectedAccountId\":\"acct_raceCm\"}');
       INSERT INTO exos_events(id,org_id,name,status,starts_at,currency) VALUES
         ('$E','$O','Race split','published',now()-interval '10 days','usd'), ('$F','$O','Race fee','published',now()-interval '10 days','usd');
       INSERT INTO exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$T','$E','GA',20,0,0), ('$TF','$F','GA',20,0,0);
       INSERT INTO exos_org_commission_settings(org_id,default_method,holdback_days,split_at_sale_enabled) VALUES ('$O','manual',3,true);
       INSERT INTO exos_event_commission_settings(event_id,org_id,method) VALUES ('$E','$O','split_at_sale'), ('$F','$O','platform_fee');" >/dev/null
$P -c "SELECT set_config('app.uid','$A',false); SELECT public.exos_upsert_promoter('$O','race-p','Race P');" >/dev/null
PR=$($P -c "SELECT id FROM exos_promoters WHERE org_id='$O' AND code='race-p'")
$P -c "SELECT set_config('app.uid','$A',false); SELECT public.exos_set_promoter_terms('$PR',1000,0);
       SELECT public.exos_record_promoter_stripe('$PR','acct_raceP',true,true,true);" >/dev/null
order() { # session tier qty fee split fee_on
  $P -c "INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,promoter_id,application_fee_cents,exos_fee_cents,card_fee_est_cents)
           SELECT '$1', event_id, '$2', '$O', '$B', 'buyer@race-cm.example', $3, $3 * 2000, 'pending', 'race-p', $4, $4, 0 FROM exos_ticket_tiers WHERE id='$2';
         SELECT public.exos_record_commission_plan('$1', public.exos_commission_checkout_plan((SELECT event_id FROM exos_ticket_tiers WHERE id='$2'),'$2','race-p',$3,$3*2000,0,0,$4,'stripe',$5,$6));
         SELECT public.exos_fulfill_checkout('$1');
         INSERT INTO exos_order_payments(session_id,org_id,event_id,payment_intent,charge_id,amount_cents,currency,status,transfer_id)
           SELECT '$1','$O',event_id,'pi_'||replace('$1','-',''),'ch_'||replace('$1','-',''),$3*2000,'usd','succeeded',
                  CASE WHEN $5 THEN NULL ELSE 'tr_'||replace('$1','-','') END FROM exos_ticket_tiers WHERE id='$2';" >/dev/null
}
order race-cm-s1 "$T" 2 200 true false
order race-cm-f1 "$TF" 1 100 false true
order race-cm-f2 "$TF" 1 100 false true

echo "race 1: two planners on one split order"
( $P -c "BEGIN; SELECT 'first planned: '||(public.exos_commission_plan_due('$O')->>'planned'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second planned: '||(public.exos_commission_plan_due('$O')->>'planned')" | sed 's/^/  /'
wait
$P -c "SELECT '  -> split transfers for the order: '||count(*)||' (expect 2), fee transfers: '||(SELECT count(*) FROM exos_commission_transfers WHERE org_id='$O' AND kind='fee_promoter')||' (expect 1)'
         FROM exos_commission_transfers WHERE session_id='race-cm-s1'"

echo "race 2: two sends on one transfer"
CT=$($P -c "SELECT id FROM exos_commission_transfers WHERE session_id='race-cm-s1' AND kind='split_org'")
( $P -c "BEGIN; SELECT 'first: '||coalesce(public.exos_ct_claim('$CT','send')->>'state', 'refused'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second: '||coalesce(public.exos_ct_claim('$CT','send')->>'error', 'claimed too (BAD)')" | sed 's/^/  /'
wait

echo "race 3: two planners on one promoter's fee sales"
$P -c "DELETE FROM exos_commission_transfers WHERE org_id='$O' AND kind='fee_promoter';
       UPDATE exos_promoter_commissions SET status='accrued', payout_id=NULL, paid_at=NULL WHERE org_id='$O' AND method='platform_fee';
       DELETE FROM exos_promoter_payouts WHERE org_id='$O' AND via='platform_fee';" >/dev/null
( $P -c "BEGIN; SELECT 'first planned: '||(public.exos_commission_plan_due('$O')->>'planned'); SELECT pg_sleep(2); COMMIT;" | sed 's/^/  /' ) &
sleep 0.5
$P -c "SELECT 'second planned: '||(public.exos_commission_plan_due('$O')->>'planned')" | sed 's/^/  /'
wait
$P -c "SELECT '  -> fee transfers: '||count(*)||' (expect 1), amount '||coalesce(sum(amount_cents),0)||' (expect 400)' FROM exos_commission_transfers WHERE org_id='$O' AND kind='fee_promoter'"
cleanup
