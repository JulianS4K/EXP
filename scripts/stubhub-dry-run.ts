// Dry run of StubHub event creation for one Exos event: the exact code path
// exos-distribute uses, with nothing sent to StubHub.
//
//   npx tsx scripts/stubhub-dry-run.ts event.json      # an exos_events row as JSON
//   echo '{...}' | npx tsx scripts/stubhub-dry-run.ts  # or on stdin
//
// Add "allocation": { "qty": 20, "tier": { "name": "GA", "price": 40 },
// "stubhub_event_id": "104857" (optional) } to the JSON to also plan the
// StubHub listing for those seats (with purchase_limits.maxPerOrder capping
// what one buyer sees at once).
//
// Prints: what Exos reads off the event, the local date the catalog search
// would use, whether the event can be requested (or what the organizer must
// fix), and the request StubHubWriter would send (dry-run mode never calls
// fetch). The event-editor status line is printed too.
import { readFileSync } from 'node:fs';
import { exosEventRef, localDate, stubHubChannel } from '../src/lib/marketplace';
import { ListingMappingError, StubHubWriter, planStubHubEventRequest, planStubHubListing, type RequestedEvent } from '../src/lib/marketplace/stubhub';
import { stubHubStatus } from '../src/lib/marketplace/stubhubStatus';

const raw = process.argv[2] ? readFileSync(process.argv[2], 'utf8') : readFileSync(0, 'utf8');
const row = JSON.parse(raw);

console.log(`Event: ${row.name ?? '(no name)'}  [${row.id ?? 'no id'}]  status=${row.status ?? '?'}`);
const ticked = Array.isArray(row.distribution_networks) && row.distribution_networks.includes('stubhub');
const primaryOnly = row.exclusivity?.primaryMarketOnly === true;
console.log(`StubHub ticked: ${ticked}   primary market only: ${primaryOnly}`);
console.log(`Queued on publish: ${row.status === 'published' && ticked && !primaryOnly ? 'yes' : 'no'}`);

const ref = exosEventRef(row);
console.log('\n1. What Exos reads off the event');
console.log(ref ? JSON.stringify(ref, null, 2) : '   cannot describe it (needs name, start and venue)');
if (ref) console.log(`   catalog search date (venue-local): ${localDate(ref)}`);
console.log(`   catalog search: ${stubHubChannel().capabilities.findEvents ? 'on' : 'off (no STUBHUB_CLIENT_ID/SECRET): creation is planned without a match check'}`);

console.log('\n2. PUT /sellerevents plan (pass 1)');
let status;
try {
  const plan = planStubHubEventRequest(row);
  console.log(JSON.stringify(plan, null, 2));
  const res = await new StubHubWriter().requestEvent(plan.body as RequestedEvent);
  console.log('\n3. StubHubWriter (dry-run) would send');
  console.log(JSON.stringify(res, null, 2));
  status = stubHubStatus(
    { status: 'planned', error: null, external_event_id: null, planned_request: plan, last_synced_at: null },
    { stubhubTicked: ticked, published: row.status === 'published', primaryMarketOnly: primaryOnly },
  );
} catch (e) {
  if (!(e instanceof ListingMappingError)) throw e;
  console.log(`   REFUSED: ${e.message}`);
  status = stubHubStatus(
    { status: 'failed', error: e.message, external_event_id: null, planned_request: null, last_synced_at: null },
    { stubhubTicked: ticked, published: row.status === 'published', primaryMarketOnly: primaryOnly },
  );
}
console.log(`\nEvent editor would show: ${status ? `[${status.tone}] ${status.text}` : '(nothing: StubHub not ticked)'}`);

if (row.allocation) {
  console.log('\n4. StubHub listing for the allocation (pass 1b)');
  try {
    const plan = planStubHubListing({
      id: row.allocation.id ?? '00000000-0000-4000-8000-000000000000',
      requested_qty: row.allocation.qty,
      unit_price: row.allocation.price ?? null,
      tier: row.allocation.tier,
      event: row,
      stubhubEventId: row.allocation.stubhub_event_id ?? null,
    });
    console.log(JSON.stringify(plan, null, 2));
    console.log(plan.display_cap
      ? `   one listing of ${row.allocation.qty}; a buyer sees at most ${plan.display_cap} at a time`
      : `   one listing of ${row.allocation.qty}; no per-order cap set on the event, so one order could take all of it`);
  } catch (e) {
    console.log(`   REFUSED: ${e instanceof Error ? e.message : e}`);
  }
}
