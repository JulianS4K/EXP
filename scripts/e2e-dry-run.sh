#!/usr/bin/env bash
# End-to-end dry run: one event from creation to the door, through Exos's own
# checkout AND StubHub, on a throwaway Postgres built from every migration.
#
#   bash scripts/e2e-dry-run.sh            # needs PGHOST/PGPORT (default /tmp/pgrun:5433)
#
# Runs the real database functions (the ones the app, the edge functions and
# the scanner call) and the real TypeScript planners exos-distribute /
# exos-marketplace-sales use. What it simulates, because it can't be real
# here: Stripe (a paid checkout session is inserted as exos-checkout would),
# StubHub (sales arrive as the webhook would deliver them; plans are printed,
# never sent), the clock (doors "open" by moving the event start), email
# delivery (exos_mail rows are checked, not sent). Every step asserts; the
# script stops at the first surprise.
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${1:-exos_e2e}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
APP="https://vibepass-storefront-test.onrender.com/bridge"

echo "== building a fresh database from every migration ($DB)"
bash tests/exos/run_p0.sh "$DB" >/tmp/e2e-build.log 2>&1 || { tail -20 /tmp/e2e-build.log; exit 1; }
PSQL="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
q()  { $PSQL -c "$1"; }
# as <uid> <email> <sql>: run as a signed-in user (RLS + auth.uid() apply)
as() {
  local out
  out=$($PSQL -c "BEGIN; SELECT set_config('app.uid','$1',true) IS NULL, set_config('app.jwt','{\"email\":\"$2\"}',true) IS NULL;
SET LOCAL ROLE authenticated; $3; COMMIT;") || return 1
  printf '%s\n' "$out" | grep -v '^f|f$' | grep -v '^$' || true
}
ok()   { echo "   ok  $*"; }
step() { echo; echo "── $*"; }
need() { [ "$1" = "$2" ] || { echo "   FAIL: expected '$2', got '$1'  ($3)"; exit 1; }; }

ORG=e2e00000-0000-0000-0000-000000000001; EV=e2e00000-0000-0000-0000-0000000000e1
GA=e2e00000-0000-0000-0000-0000000000d1;  VIP=e2e00000-0000-0000-0000-0000000000d2
OWNER=e2e00000-0000-0000-0000-0000000000a0; SCAN=e2e00000-0000-0000-0000-0000000000a2
ALICE=e2e00000-0000-0000-0000-0000000000b1; BOB=e2e00000-0000-0000-0000-0000000000b2
CAROL=e2e00000-0000-0000-0000-0000000000b3; DAVE=e2e00000-0000-0000-0000-0000000000b4
NINA_TOKEN=e2e00000-0000-0000-0000-00000000aa01

# The rotating door barcode the app shows (T-<ticket>:<owner>:<30s bucket>:<hmac>).
barcode() { q "SELECT 'T-'||t.id||':'||t.owner_id||':'||b||':'||rtrim(translate(encode(extensions.hmac(t.id||':'||t.owner_id||':'||b, t.barcode_secret,'sha256'),'base64'),'+/','-_'),'=')
               FROM public.exos_tickets t, (SELECT floor(extract(epoch FROM now())*1000/30000)::bigint${2:+ + $2} AS b) x WHERE t.id='$1'"; }
scan() { as $SCAN scanner@e2e.test "SELECT public.exos_check_in_ticket('$1','camera','barcode','$2','${3:-$EV}') ->> 'reason'" | tail -1; }

step "0. People: an organizer, a door scanner, a promoter, four fans"
q "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
   ('$OWNER','owner@e2e.test',now()), ('$SCAN','scanner@e2e.test',now()),
   ('$ALICE','alice@e2e.test',now()), ('$BOB','bob@e2e.test',now()), ('$DAVE','dave@e2e.test',now());
   INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES ('$ORG','Blue Room Presents','blue-room','$OWNER');
   INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES ('$ORG','$OWNER','owner'),('$ORG','$SCAN','scanner');
   INSERT INTO public.exos_promoters(org_id,code,name,kit_token) VALUES ('$ORG','nina','Nina','$NINA_TOKEN');
   -- The harness's stub tables carry no RLS; prod lets org staff write their
   -- events and tiers through RLS policies (phase-1 schema). Grant the same here.
   GRANT SELECT, INSERT, UPDATE ON public.exos_events, public.exos_ticket_tiers TO authenticated;"
ok "carol has no Exos account yet; she'll sign up to claim"

step "1. Organizer creates the event (draft), StubHub ticked, max 4 per order and per account"
as $OWNER owner@e2e.test "INSERT INTO public.exos_events(id,org_id,name,status,starts_at,occurs_at_local,timezone,currency,
      venue_name,venue_location,venue_address,distribution_networks,exclusivity,purchase_limits,total_tickets,created_by)
    VALUES ('$EV','$ORG','Late Night Jazz','draft',date_trunc('minute', now()+interval '30 days'),
      to_char(date_trunc('minute', now()+interval '30 days') AT TIME ZONE 'America/New_York','YYYY-MM-DD\"T\"HH24:MI:SS')
        ||CASE WHEN (now()+interval '30 days') AT TIME ZONE 'America/New_York' - (now()+interval '30 days') AT TIME ZONE 'UTC' = interval '-4 hours' THEN '-04:00' ELSE '-05:00' END,
      'America/New_York','USD',
      'Blue Room','Blue Room','{\"street\":\"1 Main St\",\"city\":\"Brooklyn\",\"region\":\"NY\",\"country\":\"United States\"}',
      ARRAY['stubhub'],'{\"primaryMarketOnly\":false}','{\"maxPerOrder\":4,\"maxPerAccount\":4}',110,'$OWNER');
  INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$GA','$EV','GA',40,100,0),('$VIP','$EV','VIP',120,10,0)" >/dev/null
need "$(q "SELECT count(*) FROM exos_distribution_listings WHERE event_id='$EV'")" 0 "draft queues nothing"
ok "draft saved: 2 ticket types, nothing queued for StubHub"

step "2. Organizer publishes"
as $OWNER owner@e2e.test "UPDATE public.exos_events SET status='published' WHERE id='$EV'" >/dev/null
need "$(q "SELECT status FROM exos_distribution_listings WHERE event_id='$EV' AND channel='stubhub'")" pending "publish queues the StubHub request"
ok "StubHub event request queued (pending)"

step "3. Organizer sets 20 GA seats aside for StubHub"
as $OWNER owner@e2e.test "SELECT public.exos_set_channel_allocation('$EV','stubhub','$GA',20)" >/dev/null
need "$(q "SELECT exos_tier_available('$GA')")" 80 "Exos keeps 80 of 100 GA"
ok "Exos can now sell 80 GA; StubHub holds 20"

step "4. exos-distribute (dry-run): StubHub event plan + listing plan"
ROW=$(q "SELECT row_to_json(x) FROM (SELECT e.id,e.name,e.status,e.starts_at,e.occurs_at_local,e.timezone,e.venue_name,e.venue_location,e.venue_address,e.currency,e.purchase_limits,
          d.id AS dist_id, d.requested_qty, t.name AS tier_name, t.price AS tier_price
          FROM exos_events e JOIN exos_distribution_listings d ON d.event_id=e.id AND d.channel='stubhub' JOIN exos_ticket_tiers t ON t.id=d.tier_id WHERE e.id='$EV') x")
PLANS=$(ROW="$ROW" npx tsx -e "
import { planStubHubEventRequest, planStubHubListing } from './src/lib/marketplace/stubhub';
const r = JSON.parse(process.env.ROW!);
const ev = planStubHubEventRequest(r);
const li = planStubHubListing({ id: r.dist_id, requested_qty: r.requested_qty, unit_price: null, tier: { name: r.tier_name, price: r.tier_price }, event: r });
console.log(JSON.stringify({ ev, li }));")
q "UPDATE exos_distribution_listings SET status='planned', planned_request='$(echo "$PLANS" | node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(0)).ev))')',
     planned_listing='$(echo "$PLANS" | node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(0)).li))')' WHERE event_id='$EV' AND channel='stubhub'"
echo "$PLANS" | node -e '
const p = JSON.parse(require("fs").readFileSync(0));
console.log(`   plan  ${p.ev.method} ${p.ev.path}: "${p.ev.body.event.name}" ${p.ev.body.event.start_date} at ${p.ev.body.venue.name}, ${p.ev.body.venue.city} ${p.ev.body.country.code}`);
console.log(`   plan  ${p.li.method} ${p.li.path}: ${p.li.body.number_of_tickets} x ${p.li.body.seating.section} @ $${p.li.body.ticket_price.amount}, buyers see ${p.li.body.display_number_of_tickets} at a time, split ${p.li.body.split_type}, unpublished`);'
ok "both plans stored; nothing sent to StubHub"

step "5. (operator-authorized send, simulated) StubHub accepts: listing SH-L-1 live on StubHub event 104857"
q "UPDATE exos_distribution_listings SET status='listed', external_listing_id='SH-L-1', external_event_id='104857' WHERE event_id='$EV' AND channel='stubhub';
   INSERT INTO exos_channel_event_links(event_id,org_id,channel,status,external_event_id,method) VALUES ('$EV','$ORG','stubhub','created','104857','created')"
ok "listing live; the 20 seats stay allocated"

step "6. Alice buys 2 GA on Exos through Nina's link (hold -> Stripe -> fulfil)"
if as $ALICE alice@e2e.test "SELECT public.exos_create_hold('$EV','$GA',5,600,NULL)" >/dev/null 2>&1; then echo "   FAIL: 5 > max per order accepted"; exit 1; fi
ok "a 5-ticket order is refused (max 4 per order)"
HOLD=$(as $ALICE alice@e2e.test "SELECT public.exos_create_hold('$EV','$GA',2,600,NULL)" | tail -1)
q "INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,promoter_id)
     VALUES ('cs_e2e_alice','$EV','$GA','$ORG','$ALICE','alice@e2e.test',2,8000,'pending','nina');
   UPDATE exos_cart_holds SET checkout_session_id='cs_e2e_alice' WHERE buyer_uid='$ALICE' AND status='active';
   SELECT exos_fulfill_checkout('cs_e2e_alice')" >/dev/null
need "$(q "SELECT count(*) FROM exos_tickets WHERE owner_id='$ALICE' AND promoter_id='nina' AND status='active'")" 2 "alice holds 2 via nina"
need "$(q "SELECT exos_tier_available('$GA')")" 78 "GA left for Exos"
ok "alice holds 2 GA (credited to nina); Exos has 78 GA left, StubHub still 20"

step "7. Bob buys 2 GA on StubHub (webhook -> record -> fulfil)"
q "SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9001\",\"external_listing_id\":\"SH-L-1\",\"quantity\":2,\"sale_status\":\"confirmed\",\"buyer_email\":\"bob@e2e.test\",\"proceeds\":\"90.00\",\"currency\":\"USD\"}');
   SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='SH-9001'),'$APP')" >/dev/null
need "$(q "SELECT status FROM exos_marketplace_orders WHERE external_order_id='SH-9001'")" fulfilled "bob's order"
need "$(q "SELECT count(*) FROM exos_transfers WHERE receiver_email='bob@e2e.test' AND status='pending'")" 2 "2 transfers to bob"
need "$(q "SELECT count(*) FROM exos_mail WHERE to_email='bob@e2e.test' AND template='transfer-initiated'")" 1 "bob emailed"
need "$(q "SELECT exos_channel_allocated('$GA')||'/'||exos_tier_available('$GA')")" "18/78" "stubhub 18 left, exos untouched"
TR=$(q "SELECT string_agg(id::text, ',') FROM exos_transfers WHERE receiver_email='bob@e2e.test'")
TR="$TR" APP="$APP" npx tsx -e "
import { planDelivery, stubHubChannel } from './src/lib/marketplace';
const p = planDelivery(stubHubChannel(), { external_order_id: 'SH-9001', quantity: 2, transfer_ids: process.env.TR!.split(',') }, process.env.APP);
if (p.kind !== 'planned') throw new Error('no plan');
console.log('   plan  ' + p.request.method + ' ' + p.request.path + ': confirmed + ' + p.claim_urls.length + ' claim links (' + p.claim_urls[0].replace(/[0-9a-f-]{36}$/, '<id>') + ')');"
ok "2 tickets parked on the organizer, transferred to bob + emailed; StubHub allocation 20 -> 18, Exos still 78"

step "8. Bob at the door BEFORE claiming: the ticket is still in transfer"
q "UPDATE exos_events SET starts_at=now()-interval '1 hour', doors_at=now()-interval '2 hours' WHERE id='$EV'"   # doors open (clock simulated)
BT=$(q "SELECT id FROM exos_tickets WHERE order_ref='stubhub:SH-9001' ORDER BY id LIMIT 1")
OLD=$(barcode $BT)
need "$(scan $BT "$OLD")" in-transfer "unclaimed ticket at the door"
ok "refused: in-transfer (nothing handed to StubHub scans before the buyer claims)"

step "9. Bob claims both tickets"
for t in $(q "SELECT id FROM exos_transfers WHERE receiver_email='bob@e2e.test' AND status='pending'"); do
  as $BOB bob@e2e.test "SELECT public.exos_claim_transfer('$t')" >/dev/null
done
need "$(q "SELECT count(*) FROM exos_tickets WHERE order_ref='stubhub:SH-9001' AND owner_id='$BOB' AND pending_transfer_id IS NULL")" 2 "bob owns both"
need "$(scan $BT "$OLD")" barcode-rejected "the pre-claim barcode"
ok "bob owns both; the barcode from before the claim no longer works (secret rotated)"

step "10. Carol (no account) buys 3 on StubHub, signs up, claims"
q "SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9002\",\"external_listing_id\":\"SH-L-1\",\"quantity\":3,\"sale_status\":\"confirmed\",\"buyer_email\":\"carol@e2e.test\",\"proceeds\":\"135.00\",\"currency\":\"USD\"}');
   SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='SH-9002'),'$APP');
   INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$CAROL','carol@e2e.test',now());" >/dev/null
for t in $(q "SELECT id FROM exos_transfers WHERE receiver_email='carol@e2e.test' AND status='pending'"); do
  as $CAROL carol@e2e.test "SELECT public.exos_claim_transfer('$t')" >/dev/null
done
need "$(q "SELECT count(*) FROM exos_tickets WHERE owner_id='$CAROL'")" 3 "carol owns 3"
ok "carol signed up with the order email and claimed 3"

step "11. Dave buys 3 + 3 on StubHub (each order within max per order), then claims all 6"
for o in SH-9003 SH-9004; do
  q "SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"$o\",\"external_listing_id\":\"SH-L-1\",\"quantity\":3,\"sale_status\":\"confirmed\",\"buyer_email\":\"dave@e2e.test\"}');
     SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='$o'),'$APP')" >/dev/null
done
need "$(q "SELECT count(*) FROM exos_account_limit_flags WHERE org_id='$ORG'")" 0 "no flag for sales alone"
ok "both sales went through; no flag yet (tickets are only on their way)"
for t in $(q "SELECT id FROM exos_transfers WHERE receiver_email='dave@e2e.test' AND status='pending'"); do
  as $DAVE dave@e2e.test "SELECT public.exos_claim_transfer('$t')" >/dev/null
done
need "$(q "SELECT held||'/'||max_per_account FROM exos_account_limit_flags WHERE user_id='$DAVE'")" "6/4" "dave flagged"
ok "dave's account holds 6 of max 4: flagged in the org's Limit flags tab"

step "12. Alice gets 3 more from a friend (Exos transfer): 5 of max 4, sold through Nina"
q "INSERT INTO exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,barcode_secret,promoter_id)
   SELECT '$EV','$ORG','$GA','$ALICE','$ALICE','active',gen_random_uuid()::text,'nina' FROM generate_series(1,3);
   UPDATE exos_ticket_tiers SET sold=sold+3 WHERE id='$GA'"
need "$(q "SELECT held||' '||array_to_string(promoter_codes,',') FROM exos_account_limit_flags WHERE user_id='$ALICE'")" "5 nina" "alice flagged via nina"
NINA=$($PSQL -c "SET ROLE anon; SELECT public.exos_promoter_limit_flags('$NINA_TOKEN')")
echo "$NINA" | node -e 'const f=JSON.parse(require("fs").readFileSync(0)); console.log(`   Nina portal: ${f.length} flag(s): ${f.map(x=>`${x.buyer} holds ${x.held}/${x.max_per_account}, ${x.from_you} through her`).join("; ")}`)'
FID=$(q "SELECT id FROM exos_account_limit_flags WHERE user_id='$ALICE'")
$PSQL -c "SET ROLE anon; SELECT public.exos_promoter_note_limit_flag('$NINA_TOKEN','$FID','Alice, buying for her band')" >/dev/null
as $OWNER owner@e2e.test "SELECT public.exos_review_account_limit_flag('$FID','OK: band, per Nina')" >/dev/null
ok "nina sees alice masked and notes her; the organizer reviews it (dave's stays open)"

step "13. Exos sells out every seat it has; StubHub still sells its own"
q "UPDATE exos_ticket_tiers SET sold = capacity - exos_channel_allocated(id) WHERE id='$GA';
   UPDATE exos_events SET tickets_sold = (SELECT sum(sold) FROM exos_ticket_tiers WHERE event_id='$EV') WHERE id='$EV'"
need "$(q "SELECT exos_seats_available('$GA',1)")" f "Exos sold out"
q "SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9005\",\"external_listing_id\":\"SH-L-1\",\"quantity\":2,\"sale_status\":\"confirmed\",\"buyer_email\":\"eve@e2e.test\"}');
   SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='SH-9005'),'$APP')" >/dev/null
need "$(q "SELECT status FROM exos_marketplace_orders WHERE external_order_id='SH-9005'")" fulfilled "stubhub sells its own seat after exos sold out"
need "$(q "SELECT sold||'/'||capacity||' '||exos_channel_allocated(id) FROM exos_ticket_tiers WHERE id='$GA'")" "93/100 7" "never over capacity"
ok "Exos: sold out. StubHub: sale fulfilled from its own seats (9 -> 7 left). GA 93/100, never over"

step "14. StubHub sells 8 when it holds 7, and cancels one it already delivered"
q "SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9006\",\"external_listing_id\":\"SH-L-1\",\"quantity\":8,\"sale_status\":\"confirmed\",\"buyer_email\":\"frank@e2e.test\"}');
   SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='SH-9006'),'$APP');
   SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9005\",\"external_listing_id\":\"SH-L-1\",\"quantity\":2,\"sale_status\":\"cancelled\"}')" >/dev/null
q "SELECT '   '||external_order_id||': '||status||' ('||coalesce(attention_reason,'-')||')' FROM exos_marketplace_orders WHERE external_order_id IN ('SH-9005','SH-9006') ORDER BY 1"
need "$(q "SELECT count(*) FROM exos_marketplace_orders WHERE external_order_id IN ('SH-9005','SH-9006') AND status='needs_attention'")" 2 "both to a human"
need "$(q "SELECT exos_channel_allocated('$GA')")" 7 "allocation untouched by the refused sale"
ok "both go to a human; nothing oversold, nothing silently undone"

step "15. Doors: the scanner at work"
AT=$(q "SELECT id FROM exos_tickets WHERE owner_id='$ALICE' AND order_ref='cs_e2e_alice' ORDER BY id LIMIT 1")
need "$(scan $AT "$(barcode $AT)")" checked-in "alice valid"
need "$(q "SELECT status FROM exos_tickets WHERE id='$AT'")" used "alice checked in"
ok "alice (Exos checkout): admitted"
need "$(scan $AT "$(barcode $AT)")" used "second scan"
ok "alice again: refused, used"
need "$(scan $BT "$(barcode $BT)")" checked-in "bob valid"
ok "bob (StubHub, claimed): admitted"
BT2=$(q "SELECT id FROM exos_tickets WHERE order_ref='stubhub:SH-9001' AND id<>'$BT' LIMIT 1")
need "$(scan $BT2 "$(barcode $BT2 -10)")" barcode-expired "screenshot from 5 min ago"
ok "bob's second ticket from a 5-minute-old screenshot: refused, barcode-expired"
need "$(scan $BT2 "$(barcode $BT2)" e2e00000-0000-0000-0000-0000000000ff)" wrong-event "wrong event"
ok "scanned at another event's door: refused, wrong-event"
q "UPDATE exos_tickets SET status='voided' WHERE id=(SELECT id FROM exos_tickets WHERE owner_id='$DAVE' LIMIT 1)"
DV=$(q "SELECT id FROM exos_tickets WHERE owner_id='$DAVE' AND status='voided' LIMIT 1")
need "$(scan $DV "$(barcode $DV)")" voided "voided"
ok "one of dave's extra tickets voided by the organizer: refused, voided"
EVE=$(q "SELECT id FROM exos_tickets WHERE order_ref='stubhub:SH-9005' LIMIT 1")
need "$(scan $EVE "$(barcode $EVE)")" in-transfer "eve never claimed"
ok "eve (cancelled StubHub order, never claimed): refused, in-transfer"

step "16. Where it ended"
q "SELECT '   GA sold '||sold||'/'||capacity||', StubHub still holds '||exos_channel_allocated(id)||', Exos can sell '||coalesce(exos_tier_available(id),0) FROM exos_ticket_tiers WHERE id='$GA'"
q "SELECT '   checked in: '||count(*) FILTER (WHERE status='used')||', voided: '||count(*) FILTER (WHERE status='voided') FROM exos_tickets WHERE event_id='$EV'"
q "SELECT '   StubHub orders: '||string_agg(status||' '||n, ', ') FROM (SELECT status, count(*) n FROM exos_marketplace_orders WHERE org_id='$ORG' GROUP BY 1 ORDER BY 1) x"
q "SELECT '   limit flags: '||count(*) FILTER (WHERE reviewed_at IS NULL)||' open, '||count(*) FILTER (WHERE reviewed_at IS NOT NULL)||' reviewed' FROM exos_account_limit_flags WHERE org_id='$ORG'"
q "SELECT '   emails queued: '||count(*) FROM exos_mail WHERE to_email LIKE '%@e2e.test'"
echo; echo "== dry run passed"
psql -h "$H" -p "$PORT" -U "$U" -qc "DROP DATABASE IF EXISTS $DB" >/dev/null
