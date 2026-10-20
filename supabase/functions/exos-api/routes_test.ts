// deno test supabase/functions/exos-api/routes_test.ts
import { ATTENDEE_SELECT, isUuid, selectedColumns } from "./routes.ts";

function check(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

// exos_tickets columns (mig 20260520130000_exos_phase2_tickets.sql + later ADD COLUMNs).
const TICKET_COLUMNS = new Set([
  "id", "event_id", "org_id", "tier_id", "tier_name", "buyer_id", "owner_id", "buyer_email", "status",
  "barcode_secret", "price_paid", "order_ref", "channel_source", "promoter_id", "pending_transfer_id",
  "transfer_id", "voided_at", "voided_by", "voided_reason", "check_in_at", "last_reissue_at",
  "created_at", "updated_at", "attendee_name",
]);

Deno.test("attendees select reads only real exos_tickets columns", () => {
  for (const c of selectedColumns(ATTENDEE_SELECT)) check(TICKET_COLUMNS.has(c), `exos_tickets has no column ${c}`);
});

Deno.test("attendees keep owner_email in the response, read from buyer_email", () => {
  check(ATTENDEE_SELECT.includes("owner_email:buyer_email"), "owner_email must alias buyer_email");
  check(selectedColumns("a, b:c").join() === "a,c", "alias parsing");
});

Deno.test("event ids must be uuids", () => {
  check(isUuid("11111111-2222-3333-4444-555555555555"), "uuid accepted");
  check(isUuid("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"), "upper-case uuid accepted");
  for (const bad of [undefined, "", "abc", "1", "11111111-2222-3333-4444-55555555555", "11111111-2222-3333-4444-555555555555x"]) {
    check(!isUuid(bad), `rejected ${bad}`);
  }
});
