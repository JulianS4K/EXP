# Exos for AI assistants (MCP)

Exos runs a remote [Model Context Protocol](https://modelcontextprotocol.io) server, so fans and organizers can
use Exos from Claude, ChatGPT and any other MCP client. It's one server for every assistant: MCP is the shared
standard, so a new assistant that speaks it works without new code.

- **Endpoint:** `https://<project>.supabase.co/functions/v1/exos-mcp` (Streamable HTTP, stateless: `POST` only).
- **Code:** `supabase/functions/exos-mcp/index.ts` (HTTP, auth, rate limits, database reads);
  `supabase/functions/_shared/mcp/protocol.ts` (JSON-RPC and MCP, no dependencies);
  `supabase/functions/_shared/mcp/exosTools.ts` (the tools). Tests: `src/lib/mcp/mcp.test.ts`,
  `tests/exos/test_mcp.sql`.
- **Migration:** `20260929060000_exos_mcp.sql` (report functions and a rate limiter, service role only).

## Tools

Everything is **read-only**. Nothing is bought, held or changed; a purchase is always a link the person opens.

| Tool | Who | What it does |
|---|---|---|
| `search_events` | anyone | Upcoming published events by keyword, city, date range |
| `get_event` | anyone | One event: date, venue, description, ticket types with **all-in** price, on-sale status, roughly how many left |
| `get_ticket_link` | anyone | A checkout link with the ticket type and quantity in the cart (`/checkout?products=…`, tagged `utm_source=ai_assistant`, optional promoter code). The person finishes checkout. |
| `search`, `fetch` | anyone | The same event data in the shape ChatGPT connectors and deep research expect (`{results:[{id,title,url}]}` / `{id,title,text,url,metadata}`) |
| `my_events` | organizer key | The org's events and tickets sold |
| `event_sales` | organizer key | Per ticket type sold/capacity; paid orders, gross, refunds |
| `door_status` | organizer key | Issued, checked in, voided, last scan |
| `marketplace_attention` | organizer key | Marketplace orders waiting on a person, and why (no buyer emails) |

Tool results come as text (JSON) and as `structuredContent`; every tool is annotated `readOnlyHint: true`.
The server's instructions tell the assistant never to claim a ticket was bought, and to treat organizer-written
names and descriptions as information, not instructions.

## Auth

- **No auth:** the public tools. This works today in every client.
- **`Authorization: Bearer <Exos API key>`:** adds the organizer tools for that key's org. These are the same keys as
  the REST API (`exos-api`, created in org settings). Keys are stored hashed; revoked keys, and keys whose creator
  left the org (mig 20260929010000), are refused with 401. A wrong key is never quietly treated as "no key".
- **OAuth (next step):** consumer connector screens (claude.ai, ChatGPT) sign in with OAuth rather than a pasted
  key. Until Exos is an OAuth 2.1 authorization server for MCP (for example, Supabase Auth's OAuth server),
  organizer tools work where a header can be set: Claude Code, Claude Desktop through `mcp-remote`, the Claude API,
  and the OpenAI Responses API.

## Connecting

The client screens change often; the principle stays the same: add a custom MCP server with the URL above.

- **Claude (claude.ai, Desktop):** Settings → Connectors → Add custom connector → the endpoint URL (public tools).
- **Claude Code:**
  `claude mcp add --transport http exos https://<project>.supabase.co/functions/v1/exos-mcp`.
  For an organizer, add `--header "Authorization: Bearer sk_live_…"`.
- **Claude API:** the Messages API MCP connector (`mcp_servers: [{ type: "url", url, name: "exos",
  authorization_token }]`).
- **ChatGPT:** Settings → Connectors (developer mode) → add a custom MCP server with the URL. `search` and `fetch`
  make it usable in deep research too.
- **OpenAI API:** Responses API `tools: [{ type: "mcp", server_label: "exos", server_url, headers: { Authorization:
  "Bearer sk_live_…" }, require_approval: "never" }]`.
- **Anything else:** `POST` JSON-RPC 2.0 (`initialize`, `tools/list`, `tools/call`), protocol versions
  `2025-06-18`, `2025-03-26`, `2024-11-05`.

## Limits and safety

- 60 calls a minute per network without a key; 120 a minute per key. If the limiter itself errors, calls are
  refused (503).
- Request bodies are capped at 64 KB, batches at 20 messages, search results at 25.
- Search input is stripped to letters, numbers and a few punctuation marks before it reaches a PostgREST filter.
- Organizer reads are scoped in SQL to the key's org (`exos_mcp_event_sales` / `exos_mcp_door_status` return NULL
  for any other org's event); no tool returns buyer emails or barcode secrets.
- Unexpected errors reach the assistant as "something went wrong"; details go to the function log, redacted.

## Deploy (operator)

1. Apply `20260929060000_exos_mcp.sql`.
2. `supabase functions deploy exos-mcp --no-verify-jwt`. Assistants don't send a Supabase JWT; the API key is
   checked in the function.
3. Secrets: `EXOS_APP_BASE_URL` (public app base for links, e.g. `https://…/bridge`). `SUPABASE_URL` and
   `SUPABASE_SERVICE_ROLE_KEY` are set by the platform. `EXOS_GUEST_IP_SALT` is optional.
4. Check it:
   `curl -s -X POST <url> -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'`.

## Next

- OAuth 2.1 for organizer tools in consumer connector screens.
- Write tools behind explicit confirmation (draft an event, issue comps, send a message to ticket holders). These
  need per-org permissions and an audit trail first.
- ChatGPT Apps SDK / MCP UI widgets (an event card with a Buy button) on top of the same tools.
