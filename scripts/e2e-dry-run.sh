#!/usr/bin/env bash
# End-to-end dry run: one event from creation to the door, through Exos's own
# checkout, StubHub AND SeatGeek, on a throwaway Postgres built from every
# migration.
#
#   bash scripts/e2e-dry-run.sh            # needs PGHOST/PGPORT (default /tmp/pgrun:5433)
#
# Runs the real database functions (the ones the app, the edge functions and
# the scanner call) and the real TypeScript planners exos-distribute /
# exos-marketplace-sales use. What it simulates, because it can't be real
# here: Stripe (a paid checkout session is inserted as exos-checkout would),
# StubHub / SeatGeek (sales arrive as the webhook would deliver them; plans
# are printed, never sent), the clock (doors "open" by moving the event start), email
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
ok "carol has no Exos account yet; she'll sign up to claim (with a different email than her StubHub order)"

step "1. Organizer creates the event (draft), StubHub + SeatGeek ticked, max 4 per order and per account"
as $OWNER owner@e2e.test "INSERT INTO public.exos_events(id,org_id,name,status,starts_at,occurs_at_local,timezone,currency,
      venue_name,venue_location,venue_address,distribution_networks,exclusivity,purchase_limits,total_tickets,created_by)
    VALUES ('$EV','$ORG','Late Night Jazz','draft',date_trunc('minute', now()+interval '30 days'),
      to_char(date_trunc('minute', now()+interval '30 days') AT TIME ZONE 'America/New_York','YYYY-MM-DD\"T\"HH24:MI:SS')
        ||CASE WHEN (now()+interval '30 days') AT TIME ZONE 'America/New_York' - (now()+interval '30 days') AT TIME ZONE 'UTC' = interval '-4 hours' THEN '-04:00' ELSE '-05:00' END,
      'America/New_York','USD',
      'Blue Room','Blue Room','{\"street\":\"1 Main St\",\"city\":\"Brooklyn\",\"region\":\"NY\",\"country\":\"United States\"}',
      ARRAY['stubhub','seatgeek'],'{\"primaryMarketOnly\":false}','{\"maxPerOrder\":4,\"maxPerAccount\":4}',110,'$OWNER');
  INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold) VALUES ('$GA','$EV','GA',40,100,0),('$VIP','$EV','VIP',120,10,0)" >/dev/null
need "$(q "SELECT count(*) FROM exos_distribution_listings WHERE event_id='$EV'")" 0 "draft queues nothing"
ok "draft saved: 2 ticket types, nothing queued for the marketplaces"

step "2. Organizer fills the Marketplaces grid before publishing: GA 20 on StubHub, VIP 6 on SeatGeek"
as $OWNER owner@e2e.test "SELECT public.exos_set_channel_allocation('$EV','stubhub','$GA',20);
  SELECT public.exos_set_channel_allocation('$EV','seatgeek','$VIP',6)" >/dev/null
need "$(q "SELECT exos_tier_available('$GA')||'/'||exos_tier_available('$VIP')")" "92/4" "Exos keeps 92 GA (StubHub holds a pool of 8), 4 VIP"
need "$(q "SELECT string_agg(channel||' '||internal_seats::text, ', ' ORDER BY channel) FROM exos_distribution_listings WHERE event_id='$EV'")" \
  "seatgeek {[1,7)}, stubhub {[1,9)}" "internal seat numbers"
ok "StubHub may sell up to 20 GA but holds a pool of 8 at a time (2 x max per order, internal seats 1-8); SeatGeek holds its 6 VIP (seats 1-6); Exos sells the other 92 GA + 4 VIP"

step "3. Organizer publishes"
as $OWNER owner@e2e.test "UPDATE public.exos_events SET status='published' WHERE id='$EV'" >/dev/null
need "$(q "SELECT string_agg(channel||' '||status, ', ' ORDER BY channel) FROM exos_distribution_listings WHERE event_id='$EV' AND tier_id IS NULL")" \
  "seatgeek pending, stubhub pending" "publish queues an event row per marketplace"
need "$(q "SELECT exos_channel_allocated('$GA')||'/'||exos_channel_allocated('$VIP')")" "8/6" "the grid survives publishing"
ok "StubHub event request + SeatGeek event row queued; the grid's seats stay set aside"

step "4. exos-distribute (dry-run): StubHub event plan + listing plan, SeatGeek listing plans"
ROW=$(q "SELECT row_to_json(x) FROM (SELECT e.id,e.name,e.status,e.starts_at,e.occurs_at_local,e.timezone,e.venue_name,e.venue_location,e.venue_address,e.currency,e.purchase_limits,
          d.id AS dist_id, d.requested_qty, d.internal_seats::text AS sh_seats, t.name AS tier_name, t.price AS tier_price,
          g.id AS sg_id, g.requested_qty AS sg_qty, g.internal_seats::text AS sg_seats, v.name AS sg_tier, v.price AS sg_price
          FROM exos_events e
          JOIN exos_distribution_listings d ON d.event_id=e.id AND d.channel='stubhub' AND d.tier_id IS NOT NULL JOIN exos_ticket_tiers t ON t.id=d.tier_id
          JOIN exos_distribution_listings g ON g.event_id=e.id AND g.channel='seatgeek' AND g.tier_id IS NOT NULL JOIN exos_ticket_tiers v ON v.id=g.tier_id
          WHERE e.id='$EV') x")
PLANS=$(ROW="$ROW" npx tsx -e "
import { planStubHubEventRequest, planStubHubListing } from './src/lib/marketplace/stubhub';
import { planSeatGeekListings } from './src/lib/marketplace/seatgeek';
import { syncListings } from './src/lib/marketplace';
const r = JSON.parse(process.env.ROW!);
const ev = planStubHubEventRequest(r);
// The same Exos listings on both marketplaces: blocks of at most max per order, internal seats, ex… ids.
const li = syncListings(planStubHubListing({ id: r.dist_id, requested_qty: r.requested_qty, unit_price: null, internal_seats: r.sh_seats, tier: { name: r.tier_name, price: r.tier_price }, event: r }), null);
const sg = syncListings(planSeatGeekListings({ id: r.sg_id, requested_qty: r.sg_qty, unit_price: null, internal_seats: r.sg_seats, tier: { name: r.sg_tier, price: r.sg_price }, event: r }), null);
console.log(JSON.stringify({ ev, li, sg }));")
field() { echo "$PLANS" | node -e "process.stdout.write(JSON.stringify(JSON.parse(require('fs').readFileSync(0)).$1))"; }
q "UPDATE exos_distribution_listings SET status='planned', planned_request='$(field ev)' WHERE event_id='$EV' AND channel='stubhub' AND tier_id IS NULL;
   UPDATE exos_distribution_listings SET planned_listing='$(field li)' WHERE event_id='$EV' AND channel='stubhub' AND tier_id='$GA';
   UPDATE exos_distribution_listings SET planned_listing='$(field sg)' WHERE event_id='$EV' AND channel='seatgeek' AND tier_id='$VIP'"
echo "$PLANS" | node -e '
const p = JSON.parse(require("fs").readFileSync(0));
console.log(`   plan  ${p.ev.method} ${p.ev.path}: "${p.ev.body.event.name}" ${p.ev.body.event.start_date} at ${p.ev.body.venue.name}, ${p.ev.body.venue.city} ${p.ev.body.country.code}`);
const id = (s) => s.replace(/ex[a-z2-7]{26}/, "ex<alloc>");
for (const l of p.li.listings) console.log(`   plan  ${l.request.method} ${l.request.path} ${id(l.listing_id)}: ${l.request.body.number_of_tickets} x ${l.request.body.seating.section} row ${l.request.body.seating.row} seats ${l.request.body.seating.seat_from}-${l.request.body.seating.seat_to} @ $${l.request.body.ticket_price.amount}, split ${l.request.body.split_type}, unpublished`);
for (const l of p.sg.listings) console.log(`   plan  ${l.request.method} ${id(l.request.path)}: ${l.request.body.quantity} x ${l.request.body.section} row ${l.request.body.row} seats ${l.request.body.seat_from}-${l.request.body.seat_thru} @ $${l.request.body.cost}, ${l.request.body.stock_type}`);'
need "$(q "SELECT jsonb_array_length(planned_listing->'listings')||' '||(planned_listing->>'action') FROM exos_distribution_listings WHERE channel='stubhub' AND tier_id='$GA'")" "2 create" "stubhub: its pool of 8 as 2 listings of 4"
need "$(q "SELECT jsonb_array_length(planned_listing->'listings')||' '||(planned_listing->>'action') FROM exos_distribution_listings WHERE channel='seatgeek' AND tier_id='$VIP'")" "2 create" "seatgeek: 2 listings of at most 4"
ok "plans stored, the same standard on both; nothing sent (StubHub GA: 2 listings of 4, seats 1-8; SeatGeek VIP: 4 + 2, seats 1-6)"

step "5. (operator-authorized send, simulated) StubHub accepts the GA listings (SH-L-1) on StubHub event 104857"
q "UPDATE exos_distribution_listings SET status='listed', external_listing_id='SH-L-1', listed_snapshot=planned_listing WHERE event_id='$EV' AND channel='stubhub' AND tier_id='$GA';
   UPDATE exos_distribution_listings SET external_event_id='104857' WHERE event_id='$EV' AND channel='stubhub' AND tier_id IS NULL;
   INSERT INTO exos_channel_event_links(event_id,org_id,channel,status,external_event_id,method) VALUES ('$EV','$ORG','stubhub','created','104857','created')"
ok "listings live; the 8 held seats stay set aside"

step "6. Alice buys 2 GA on Exos through Nina's link (hold -> Stripe -> fulfil)"
if as $ALICE alice@e2e.test "SELECT public.exos_create_hold('$EV','$GA',5,600,NULL)" >/dev/null 2>&1; then echo "   FAIL: 5 > max per order accepted"; exit 1; fi
ok "a 5-ticket order is refused (max 4 per order)"
HOLD=$(as $ALICE alice@e2e.test "SELECT public.exos_create_hold('$EV','$GA',2,600,NULL)" | tail -1)
q "INSERT INTO exos_checkout_sessions(session_id,event_id,tier_id,org_id,buyer_uid,buyer_email,quantity,amount_cents,status,promoter_id)
     VALUES ('cs_e2e_alice','$EV','$GA','$ORG','$ALICE','alice@e2e.test',2,8000,'pending','nina');
   UPDATE exos_cart_holds SET checkout_session_id='cs_e2e_alice' WHERE buyer_uid='$ALICE' AND status='active';
   SELECT exos_fulfill_checkout('cs_e2e_alice')" >/dev/null
need "$(q "SELECT count(*) FROM exos_tickets WHERE owner_id='$ALICE' AND promoter_id='nina' AND status='active'")" 2 "alice holds 2 via nina"
need "$(q "SELECT exos_tier_available('$GA')")" 90 "GA left for Exos"
ok "alice holds 2 GA (credited to nina); Exos has 90 GA left, StubHub still holds 8"

step "7. Bob buys 2 GA on StubHub (webhook -> record -> fulfil)"
SHA=$(q "SELECT id FROM exos_distribution_listings WHERE channel='stubhub' AND tier_id='$GA'")
SHL=$(q "SELECT planned_listing->'listings'->1->>'listing_id' FROM exos_distribution_listings WHERE id='$SHA'")
# The sale names the Exos listing it sold from (normalizeStubHubSale: allocation + listing_ref).
q "SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9001\",\"external_listing_id\":\"$SHA\",\"listing_ref\":\"$SHL\",\"quantity\":2,\"sale_status\":\"confirmed\",\"buyer_email\":\"bob@e2e.test\",\"proceeds\":\"90.00\",\"currency\":\"USD\"}');
   SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='SH-9001'),'$APP')" >/dev/null
need "$(q "SELECT status FROM exos_marketplace_orders WHERE external_order_id='SH-9001'")" fulfilled "bob's order"
need "$(q "SELECT count(*) FROM exos_transfers WHERE receiver_email='bob@e2e.test' AND status='pending'")" 2 "2 transfers to bob"
need "$(q "SELECT count(*) FROM exos_mail WHERE to_email='bob@e2e.test' AND template='transfer-initiated'")" 1 "bob emailed"
need "$(q "SELECT exos_channel_allocated('$GA')||'/'||exos_tier_available('$GA')")" "8/88" "stubhub sold 2 and was topped back up to 8 from the free seats"
need "$(q "SELECT string_agg(internal_seat::text, ',' ORDER BY internal_seat) FROM exos_tickets WHERE order_ref='stubhub:SH-9001'")" "7,8" "bob's seats come from the listing he bought (block 5-8)"
TR=$(q "SELECT string_agg(id::text, ',') FROM exos_transfers WHERE receiver_email='bob@e2e.test'")
TR="$TR" APP="$APP" npx tsx -e "
import { planDelivery, stubHubChannel } from './src/lib/marketplace';
const p = planDelivery(stubHubChannel(), { external_order_id: 'SH-9001', quantity: 2, transfer_ids: process.env.TR!.split(','), seats: [8, 7] }, process.env.APP);
if (p.kind !== 'planned') throw new Error('no plan');
console.log('   plan  ' + p.steps[0].method + ' ' + p.steps[0].path + ': confirmed + ' + p.claim_urls.length + ' claim links (' + p.claim_urls[0].replace(/[0-9a-f-]{36}$/, '<id>') + ')');"
ok "2 tickets parked on the organizer, transferred to bob + emailed; StubHub sold 2 and holds 8 again (topped up), Exos has 88"

step "8. Bob at the door BEFORE claiming: the ticket is still in transfer"
START=$(q "SELECT starts_at FROM exos_events WHERE id='$EV'")
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
# Back to a month out for the marketplace sales below: from 3 hours before
# doors the marketplaces stop selling (scarcity mode, mig 20260928040000).
q "UPDATE exos_events SET starts_at='$START', doors_at=NULL WHERE id='$EV'"

step "10. Carol (no account) buys 3 on StubHub under a relay email, signs up with her own, claims"
RELAY=c4r0l-7x2@relay.stubhub.example
q "SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9002\",\"external_listing_id\":\"SH-L-1\",\"quantity\":3,\"sale_status\":\"confirmed\",\"buyer_email\":\"$RELAY\",\"proceeds\":\"135.00\",\"currency\":\"USD\"}');
   SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='SH-9002'),'$APP');
   INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$CAROL','carol@e2e.test',now());" >/dev/null
need "$(q "SELECT count(*) FROM exos_mail WHERE to_email='$RELAY' AND html LIKE '%any Exos account%'")" 1 "the claim mail goes to the relay and says any account"
FIRST=$(q "SELECT id FROM exos_transfers WHERE receiver_email='$RELAY' AND status='pending' ORDER BY id LIMIT 1")
need "$(as $ALICE alice@e2e.test "SELECT event_title FROM public.exos_transfer_claim_preview('$FIRST')")" "Late Night Jazz" "claim page preview for someone RLS hides the row from"
for t in $(q "SELECT id FROM exos_transfers WHERE receiver_email='$RELAY' AND status='pending'"); do
  as $CAROL carol@e2e.test "SELECT public.exos_claim_transfer('$t')" >/dev/null
done
need "$(q "SELECT count(*) FROM exos_tickets WHERE owner_id='$CAROL'")" 3 "carol owns 3"
if as $ALICE alice@e2e.test "SELECT public.exos_claim_transfer('$FIRST')" >/dev/null 2>&1; then
  echo "   FAIL: a claimed link was claimed again"; exit 1
fi
need "$(q "SELECT count(*) FROM exos_tickets WHERE owner_id='$CAROL'")" 3 "carol keeps all 3"
ok "carol claimed 3 into carol@e2e.test (order email was a StubHub relay); a second claim on her link is refused"

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
need "$(q "SELECT sold||'/'||capacity||' '||exos_channel_allocated(id) FROM exos_ticket_tiers WHERE id='$GA'")" "94/100 6" "never over capacity"
ok "Exos: sold out. StubHub: sale fulfilled from its own pool (8 -> 6; no free seats left to top it up). GA 94/100, never over"

step "14. StubHub sells 8 when it holds 6, and cancels one it already delivered"
q "SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9006\",\"external_listing_id\":\"SH-L-1\",\"quantity\":8,\"sale_status\":\"confirmed\",\"buyer_email\":\"frank@e2e.test\"}');
   SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='SH-9006'),'$APP');
   SELECT exos_record_marketplace_order('{\"channel\":\"stubhub\",\"external_order_id\":\"SH-9005\",\"external_listing_id\":\"SH-L-1\",\"quantity\":2,\"sale_status\":\"cancelled\"}')" >/dev/null
q "SELECT '   '||external_order_id||': '||status||' ('||coalesce(attention_reason,'-')||')' FROM exos_marketplace_orders WHERE external_order_id IN ('SH-9005','SH-9006') ORDER BY 1"
need "$(q "SELECT count(*) FROM exos_marketplace_orders WHERE external_order_id IN ('SH-9005','SH-9006') AND status='needs_attention'")" 2 "both to a human"
need "$(q "SELECT exos_channel_allocated('$GA')")" 6 "pool untouched by the refused sale"
ok "both go to a human; nothing oversold, nothing silently undone"

step "14b. SeatGeek sells 2 VIP on its second listing; then the organizer takes SeatGeek off"
SGA=$(q "SELECT id FROM exos_distribution_listings WHERE channel='seatgeek' AND tier_id='$VIP'")
SGL=$(q "SELECT planned_listing->'listings'->1->'body'->>'seller_listing_id' FROM exos_distribution_listings WHERE id='$SGA'")
q "SELECT exos_record_marketplace_order(jsonb_build_object('channel','seatgeek','external_order_id','SG-5001','external_listing_id','$SGA',
     'quantity',2,'sale_status','confirmed','buyer_email','gina@e2e.test','proceeds','200.00','currency','USD',
     'raw',jsonb_build_object('id','SG-5001','listing',jsonb_build_object('id','$SGL','quantity',2))));
   SELECT exos_fulfil_marketplace_order((SELECT id FROM exos_marketplace_orders WHERE external_order_id='SG-5001'),'$APP')" >/dev/null
need "$(q "SELECT string_agg(internal_seat::text, ',' ORDER BY internal_seat) FROM exos_tickets WHERE order_ref='seatgeek:SG-5001'")" "5,6" "the listing's own seats"
need "$(q "SELECT internal_seats::text||' '||requested_qty FROM exos_distribution_listings WHERE id='$SGA'")" "{[1,5)} 4" "seatgeek keeps 1-4"
need "$(q "SELECT count(*) FROM exos_mail WHERE to_email='gina@e2e.test' AND subject LIKE '%SeatGeek%'")" 1 "gina emailed"
ok "gina's 2 VIP carry internal seats 5 and 6 (staff only, never shown to her); SeatGeek keeps VIP 1-4"
as $OWNER owner@e2e.test "UPDATE public.exos_events SET distribution_networks=ARRAY['stubhub'] WHERE id='$EV'" >/dev/null
need "$(q "SELECT status||' '||requested_qty FROM exos_distribution_listings WHERE id='$SGA'")" "delisted 0" "nothing was live: released at once"
need "$(q "SELECT exos_tier_available('$VIP')")" 8 "VIP back to Exos (10 - 2 sold)"
need "$(q "SELECT status FROM exos_distribution_listings WHERE channel='stubhub' AND tier_id='$GA'")" listed "stubhub untouched"
ok "SeatGeek unticked: its 4 unsold VIP seats come straight back to Exos (nothing was live there)"
as $OWNER owner@e2e.test "SELECT public.exos_set_channel_allocation('$EV','stubhub','$GA',0)" >/dev/null
need "$(q "SELECT status||' '||exos_channel_allocated('$GA') FROM exos_distribution_listings WHERE channel='stubhub' AND tier_id='$GA'")" "delisting 6" "live: delist first"
PLAN=$(q "SELECT listed_snapshot FROM exos_distribution_listings WHERE channel='stubhub' AND tier_id='$GA'" | npx tsx -e "
import { planDelist } from './src/lib/marketplace';
const p = planDelist('stubhub', JSON.parse(require('fs').readFileSync(0, 'utf8')));
console.log(p!.requests.length + ' x ' + p!.requests[0].method + ' ' + p!.requests[0].path.replace(/ex[a-z2-7]{26}/, 'ex<alloc>'));")
echo "   plan  $PLAN"
q "UPDATE exos_distribution_listings SET status='delisted', requested_qty=0, internal_seats='{}', listed_snapshot=NULL WHERE channel='stubhub' AND tier_id='$GA'"
need "$(q "SELECT exos_channel_allocated('$GA')")" 0 "released after the delist"
ok "StubHub GA set to 0 while live: delist planned, the 6 held seats stay set aside until StubHub confirms, then return to Exos"

step "15. Doors: the scanner at work"
q "UPDATE exos_events SET starts_at=now()-interval '1 hour', doors_at=now()-interval '2 hours' WHERE id='$EV'"   # doors open again
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
q "SELECT '   '||name||' sold '||sold||'/'||capacity||', marketplaces hold '||exos_channel_allocated(id)||', Exos can sell '||coalesce(exos_tier_available(id),0) FROM exos_ticket_tiers WHERE event_id='$EV' ORDER BY name"
q "SELECT '   checked in: '||count(*) FILTER (WHERE status='used')||', voided: '||count(*) FILTER (WHERE status='voided') FROM exos_tickets WHERE event_id='$EV'"
q "SELECT '   marketplace orders: '||string_agg(channel||' '||status||' '||n, ', ') FROM (SELECT channel, status, count(*) n FROM exos_marketplace_orders WHERE org_id='$ORG' GROUP BY 1, 2 ORDER BY 1, 2) x"
q "SELECT '   limit flags: '||count(*) FILTER (WHERE reviewed_at IS NULL)||' open, '||count(*) FILTER (WHERE reviewed_at IS NOT NULL)||' reviewed' FROM exos_account_limit_flags WHERE org_id='$ORG'"
q "SELECT '   emails queued: '||count(*) FROM exos_mail WHERE to_email LIKE '%@e2e.test'"
echo; echo "== dry run passed"
psql -h "$H" -p "$PORT" -U "$U" -qc "DROP DATABASE IF EXISTS $DB" >/dev/null
