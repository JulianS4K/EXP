# Posh

Posh (posh.vip) is primary ticketing used by party and nightlife promoters. In the
distribution layer (`SPEC-DISTRIBUTION-LAYER.md` §5) it is the **capped tier** channel:
Exos can't read or write Posh's capacity, so Posh sells from a fixed number of seats
carved out of one Exos ticket type, and Posh's webhooks report each sale.

Built: mig `20261029150000_exos_posh_webhooks.sql`, edge function `exos-posh-webhook`,
parser `supabase/functions/_shared/posh/payload.ts` (+ `payload_test.ts`), SQL harness
`tests/exos/test_posh_webhooks.sql`, UI `PoshIntegrationPanel` (Org settings) and
`PoshPanel` (Edit event). Organizer steps: `docs/organizer-guide.md` "Selling on Posh too".

## What Posh offers (checked 2026-10-29)

| Item | Status | Source |
|---|---|---|
| Organizer REST API | **none** | — |
| Webhooks, set in Posh → Organization Settings → API Webhooks | documented | [A guide to webhooks at Posh](https://posh.vip/university/post/a-guide-to-webhooks-at-posh), [How to receive real-time purchase data with webhooks](https://support.posh.vip/en/articles/10723719-how-to-receive-real-time-purchase-data-with-webhooks) |
| Event "Order Created" (purchase complete) | documented | same |
| Event "Pending Order Created" (purchase waiting for organizer approval) | documented | same |
| Payload format (field names, nesting) | **not verified** | posh.vip is blocked from the build sandbox; a web search found no third-party example (Zapier / Make / n8n templates, GitHub code) |
| Request signature / shared secret | **none documented** | — |
| Retries, timeouts, ordering | **not verified** | — |
| Refund / cancellation webhook | **none documented** | — |
| Whether approving a pending order sends "Order Created" for the same order id | **assumed**, not verified | — |

Every Posh call is inbound. Exos never sends anything to Posh (there is nothing to call).

## The receiver

`POST /functions/v1/exos-posh-webhook/<token>` (deploy with `--no-verify-jwt`).

- **Auth is the URL.** `<token>` is 32 random bytes (64 hex) from `exos_posh_connect`,
  shown to the organizer once and stored only as its SHA-256 (`exos_posh_hooks.token_hash`).
  Connecting again rotates it; switching off (`exos_posh_disconnect`) refuses it. An unknown
  or disabled token gets 404. With no documented signature there is nothing else to verify;
  the log keeps the **names** of the request headers (never values) so a signature header can
  be spotted on the first real delivery and checked from then on. The token does appear in
  the edge function's request logs.
- **Limits**: 64 KB body (413), 120 deliveries a minute per URL (`exos_rate_hit`, 429; 503 if
  the limiter errors).
- `/<token>/pending` is the same URL with a hint, for an organizer who gives Pending Order
  Created its own URL. The payload's own type field wins over the hint.
- `/replay/<log id>` (header `x-cron-secret`) re-runs a logged delivery through the parser,
  for after a parser fix.

## The parser (tolerant, because the format is unknown)

`payload.ts` reads JSON (or a form post, with JSON in `payload` / `data`), then looks for each
field under the names webhook senders commonly use, at the top level and under `data` /
`payload` / `order`, in snake_case and camelCase:

| Field | Looked for in |
|---|---|
| kind | `type`, `event_type`, `webhookType`, `trigger`, `topic`, `action`, an exact `event` name ("Order Created", "Pending Order Created"); else a `status` like `pending_approval` / `requiresApproval: true`; else the URL hint; else Order Created |
| order id | `order_id`, `orderId`, `order_number`, `confirmation_code`…; a bare `id` / `_id` only inside an `order` object |
| Posh event | `event_id` / `event.id`; `event_slug` / `event.slug` / a `posh.vip/e/<slug>` URL; `event_name` / `event.name` / `event.title` |
| buyer | `buyer_email`, `email`, `customer.email`, `account.email`…; `buyer_name`, `first_name` + `last_name`, `account.firstName`… |
| tickets | arrays `tickets` / `items` / `line_items` / `attendees`…, each with a name, `quantity` and a code (`code`, `barcode`, `qr_code`, `ticket_id`… or a `codes` array) |
| quantity | `quantity`, `ticket_count`, `numberOfTickets`…; else the items' quantities; else the number of codes |
| money | `total`, `total_price`, `amount` ("$50.00" is fine), `*_cents` divided by 100; `currency` |

Anything it can't place is left out, and `exos_posh_ingest` re-checks every value (an order id
must look like an id, an email like an email, quantity 1–100), so a wrong guess drops a field,
never invents a seat. The Deno tests pin several plausible shapes; they are guesses, not Posh's
documented format. **First real delivery: compare it to this table** (the log row has the
payload) and adjust the parser.

## Data model (all tables service role only; RPCs are the client surface)

| Table | What |
|---|---|
| `exos_posh_hooks` | one per org: token hash + hint, status, retention days (30), counters, last received |
| `exos_posh_event_links` | Posh event reference (id / slug / name, lower-cased) → Exos event |
| `exos_posh_caps` | one per event: the Exos ticket type, `cap`, `cap_used` (sold inside the cap), `over_qty` / `over_acked` (past the cap), `uncovered_qty` |
| `exos_posh_orders` | one per Posh order: `order_key` (`o:<Posh id>` or `h:<body sha256>`), event (NULL = unmatched), state `pending` / `confirmed` / `cancelled`, quantity, codes, buyer name + email, how it was counted |
| `exos_posh_webhook_log` | every delivery: body hash (unique per org), kind, outcome, header names, the payload with phones, addresses, answers and other extra personal fields removed; deleted after the retention window |

How the count works:

- **The cap holds its seats.** `exos_channel_allocated` (patched, marker `_exos_posh_reserved`)
  adds `cap - cap_used` for the tier, so `exos_tier_available` and `exos_event_house_available`
  (and with them checkout, comps, the box office and Eventbrite's / Luma's shared counts) leave
  them out. Growing the cap needs that many free seats now, under the tier row's lock.
- **A confirmed order** takes `min(quantity, cap - cap_used)` from the cap: the tier's `sold` and
  the event's `tickets_sold` go up, the reserve goes down, Exos's free count doesn't move.
- **Past the cap is an oversell** (spec §5 rule 3), never silent: `over_qty` on the order and
  the cap, an attention line, a note on the buyer's door entry, and a red flag on Edit event →
  Posh until acknowledged. Those tickets still take free Exos seats if there are any (the buyer
  is real; Exos must stop selling the seat); what no free seat covers is `uncovered_qty`.
- **Pending** orders take nothing and get no door entry. An Order Created for the same order key
  confirms them; a pending delivery after that is ignored.
- **Idempotent**: one order per `(org, order_key)`; an identical body is skipped by the log.
- **No cap yet**: confirmed orders wait (attention "no Posh cap is set"); setting the first cap
  counts them.
- **Cancel** (`exos_posh_cancel_order`, after a refund on Posh): seats back to the cap, door
  entries voided.
- **Not the resale allocation**: `exos_distribution_listings` rows are read by the resale rules
  (the 250 minimum, the pool planners, the auto split, the distribute worker), so Posh has its
  own table and none of them apply.

## RPCs

| Function | Who |
|---|---|
| `exos_posh_connect(org)` → token once / `exos_posh_disconnect(org)` | owner, manager |
| `exos_posh_status(org)` (URL hint, last received, counts, links, unmatched; no token, no emails) | owner, manager, finance |
| `exos_posh_link_event(org, ref, event, label)` / `exos_posh_unlink_event(link)` / `exos_posh_assign_order(order, event)` | owner, manager |
| `exos_posh_set_cap(event, tier, cap)` / `exos_posh_ack_oversell(event)` / `exos_posh_cancel_order(order)` | owner, manager |
| `exos_posh_event_status(event)` (cap, sales, orders with buyer name + email) | owner, manager, finance |
| `exos_posh_ingest(...)`, `exos_posh_log_payload(log)`, `_exos_posh_*` helpers | service role only |

## Deploying (needs operator permission)

1. Apply `20261029150000_exos_posh_webhooks.sql`.
2. `supabase functions deploy exos-posh-webhook --no-verify-jwt` (secrets: the platform's
   `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`, and `CRON_SECRET` for replay).
3. With one organizer: make the URL, add it in Posh, buy one test ticket, and check the log row
   against the parser table above before relying on it.
