// DICE, read only: the half of exos-dice-import that talks to DICE's partner
// Ticket Holders API (GraphQL; mig 20261106100000, docs/dice-coverage.md).
// No Deno or Node APIs beyond fetch (injected), so vitest imports it too
// (src/lib/diceClient.test.ts).
//
// READ ONLY BY CONSTRUCTION (CLAUDE.md: upstream ticketing APIs are
// read-only). DICE's API is GraphQL over HTTP POST, so the guard is on the
// OPERATION, not the HTTP method: every document goes through
// assertQueryOnly, which parses it and throws on any `mutation` or
// `subscription` operation (and on anything that isn't a query or a
// fragment). diceQuery is the only function that sends a request, and it
// calls the guard first. One fixed endpoint (DICE_ENDPOINT), no redirects,
// a timeout per request.
//
// The token is the promoter's MIO API token, sent only in the Authorization
// header (never in a URL, never logged). Error text is ours or DICE's
// GraphQL error code, never a response body.

export const DICE_ENDPOINT = "https://partners-endpoint.dice.fm/graphql";
/** The only GraphQL operation type this client may send. */
export const ALLOWED_OPERATIONS: ReadonlySet<string> = new Set(["query"]);
export const TIMEOUT_MS = 20_000;
/** DICE pages: `first` is at most this. */
export const MAX_PAGE_SIZE = 50;
/** Re-read this much before the cursor: clock skew between us and DICE. */
export const CURSOR_OVERLAP_MS = 5 * 60_000;
/** Retries after the first try, on 429 / 5xx / network errors / timeouts. */
export const MAX_RETRIES = 4;
const BACKOFF_BASE_MS = 500;
const BACKOFF_MAX_MS = 30_000;

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;
export type Sleep = (ms: number) => Promise<void>;
const realSleep: Sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- The guard -------------------------------------------------------------

export class DiceWriteRefused extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DiceWriteRefused";
  }
}

/**
 * The operation types of a GraphQL document, in order ('query' for the
 * `{ … }` shorthand). Comments, strings and block strings are skipped, so a
 * word inside them is never mistaken for a keyword; only top-level
 * definitions are looked at, so a FIELD named `mutation` is fine. Throws
 * DiceWriteRefused on a document it can't read (unbalanced braces, a
 * definition that is not an operation or a fragment).
 */
export function operationTypes(doc: string): string[] {
  if (typeof doc !== "string" || doc.length === 0 || doc.length > 100_000) {
    throw new DiceWriteRefused("dice: empty or oversized GraphQL document");
  }
  const ops: string[] = [];
  let depth = 0;       // { } nesting
  let parens = 0;      // ( ) nesting at the top level (variable definitions)
  let expectDef = true; // the next top-level token starts a definition
  let i = 0;
  const n = doc.length;
  while (i < n) {
    const c = doc[i];
    if (c === "#") { // comment to end of line
      while (i < n && doc[i] !== "\n" && doc[i] !== "\r") i++;
      continue;
    }
    if (c === '"') {
      if (doc.startsWith('"""', i)) { // block string
        const end = doc.indexOf('"""', i + 3);
        if (end < 0) throw new DiceWriteRefused("dice: unterminated block string");
        i = end + 3;
        continue;
      }
      i++;
      while (i < n && doc[i] !== '"') {
        if (doc[i] === "\\") i++;
        if (doc[i] === "\n") throw new DiceWriteRefused("dice: unterminated string");
        i++;
      }
      if (i >= n) throw new DiceWriteRefused("dice: unterminated string");
      i++;
      continue;
    }
    if (c === "{") {
      if (depth === 0 && parens === 0 && expectDef) { ops.push("query"); expectDef = false; } // shorthand
      depth++;
      i++;
      continue;
    }
    if (c === "}") {
      depth--;
      if (depth < 0) throw new DiceWriteRefused("dice: unbalanced braces");
      if (depth === 0) expectDef = true;
      i++;
      continue;
    }
    if (depth === 0) {
      if (c === "(") { parens++; i++; continue; }
      if (c === ")") { parens--; if (parens < 0) throw new DiceWriteRefused("dice: unbalanced parentheses"); i++; continue; }
      if (/[_A-Za-z]/.test(c)) {
        let j = i + 1;
        while (j < n && /[_0-9A-Za-z]/.test(doc[j])) j++;
        const word = doc.slice(i, j);
        if (expectDef && parens === 0) {
          if (word === "query" || word === "mutation" || word === "subscription") ops.push(word);
          else if (word === "fragment") ops.push("fragment");
          else throw new DiceWriteRefused(`dice: unsupported definition "${word.slice(0, 40)}"`);
          expectDef = false;
        }
        i = j;
        continue;
      }
    }
    i++;
  }
  if (depth !== 0 || parens !== 0) throw new DiceWriteRefused("dice: unbalanced document");
  return ops;
}

/** Throws unless the document holds query operations (and fragments) only. */
export function assertQueryOnly(doc: string): void {
  const ops = operationTypes(doc);
  const bad = ops.find((o) => o !== "fragment" && !ALLOWED_OPERATIONS.has(o));
  if (bad) throw new DiceWriteRefused(`dice: ${bad} operations are not allowed (read-only client)`);
  if (!ops.some((o) => ALLOWED_OPERATIONS.has(o))) throw new DiceWriteRefused("dice: the document has no query");
}

// ---- One request -----------------------------------------------------------

export interface DiceResult<T> {
  ok: boolean;
  status: number;
  data: T | null;
  /** Our code (HTTP_401, TIMEOUT, NETWORK, GRAPHQL, BAD_RESPONSE) on a failed request. */
  error?: string;
  /** GraphQL errors that came WITH data (e.g. a restricted field): messages only, at most 5, 200 chars each. */
  warnings: string[];
  /** Tries made (1 = no retry). */
  attempts: number;
}

export interface DiceOptions {
  fetch: Fetch;
  sleep?: Sleep;
  /** For jitter; Math.random by default. */
  random?: () => number;
  maxRetries?: number;
  timeoutMs?: number;
}

/** A token's shape as Exos stores it (the SQL checks the same). */
export function isDiceTokenShaped(t: unknown): t is string {
  return typeof t === "string" && /^[A-Za-z0-9._~+/=-]{16,2048}$/.test(t);
}

/** Wait before retry `attempt` (1-based): Retry-After when DICE sends one, else exponential with jitter. */
export function backoffMs(attempt: number, retryAfter: string | null, random: () => number = Math.random): number {
  if (retryAfter) {
    const secs = Number(retryAfter);
    if (Number.isFinite(secs) && secs >= 0) return Math.min(secs * 1000, BACKOFF_MAX_MS);
    const at = Date.parse(retryAfter);
    if (Number.isFinite(at)) return Math.min(Math.max(at - Date.now(), 0), BACKOFF_MAX_MS);
  }
  const base = Math.min(BACKOFF_BASE_MS * 2 ** (attempt - 1), BACKOFF_MAX_MS);
  return Math.round(base / 2 + random() * (base / 2));
}

const retryable = (status: number) => status === 429 || status === 0 || (status >= 500 && status <= 599);

/**
 * POST one GraphQL QUERY to DICE_ENDPOINT. Refuses anything else before a
 * byte is sent (assertQueryOnly throws). Retries 429 / 5xx / network errors
 * / timeouts with backoff. Never throws for an HTTP or network failure: those
 * come back as ok false.
 */
export async function diceQuery<T>(
  opts: DiceOptions, token: string, query: string, variables: Record<string, unknown> = {},
): Promise<DiceResult<T>> {
  assertQueryOnly(query);
  const sleep = opts.sleep ?? realSleep;
  const random = opts.random ?? Math.random;
  const maxRetries = Math.max(0, Math.min(opts.maxRetries ?? MAX_RETRIES, 8));
  const timeoutMs = opts.timeoutMs ?? TIMEOUT_MS;
  const body = JSON.stringify({ query, variables });
  let last: DiceResult<T> = { ok: false, status: 0, data: null, error: "NETWORK", warnings: [], attempts: 0 };
  for (let attempt = 1; attempt <= maxRetries + 1; attempt++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    let retryAfter: string | null = null;
    try {
      const res = await opts.fetch(DICE_ENDPOINT, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json" },
        body,
        signal: ctrl.signal,
        redirect: "error",
      });
      retryAfter = res.headers.get("retry-after");
      const parsed = await res.json().catch(() => null) as { data?: unknown; errors?: unknown } | null;
      if (!res.ok) {
        last = { ok: false, status: res.status, data: null, error: `HTTP_${res.status}`, warnings: [], attempts: attempt };
      } else if (!parsed || typeof parsed !== "object") {
        last = { ok: false, status: res.status, data: null, error: "BAD_RESPONSE", warnings: [], attempts: attempt };
      } else {
        const warnings = gqlMessages(parsed.errors);
        if (parsed.data === null || parsed.data === undefined) {
          // GraphQL failed as a whole (often HTTP 200): an auth error or a bad query.
          const unauth = warnings.some((m) => /unauth|forbidden|not authori[sz]ed|invalid token/i.test(m));
          return { ok: false, status: unauth ? 401 : res.status, data: null, error: unauth ? "HTTP_401" : "GRAPHQL", warnings, attempts: attempt };
        }
        return { ok: true, status: res.status, data: parsed.data as T, warnings, attempts: attempt };
      }
    } catch (err) {
      if (err instanceof DiceWriteRefused) throw err;
      last = {
        ok: false, status: 0, data: null, warnings: [], attempts: attempt,
        error: (err as Error)?.name === "AbortError" ? "TIMEOUT" : "NETWORK",
      };
    } finally {
      clearTimeout(timer);
    }
    if (!retryable(last.status) || attempt > maxRetries) break;
    await sleep(backoffMs(attempt, retryAfter, random));
  }
  return last;
}

function gqlMessages(errors: unknown): string[] {
  if (!Array.isArray(errors)) return [];
  return errors.slice(0, 5).map((e) => {
    const m = e && typeof e === "object" ? (e as { message?: unknown }).message : null;
    return typeof m === "string" ? m.replace(/\s+/g, " ").slice(0, 200) : "GraphQL error";
  });
}

/** What the organizer sees when a request fails. */
export function diceErrorMessage(r: { status: number; error?: string }): string {
  if (r.status === 401 || r.status === 403 || r.error === "HTTP_401" || r.error === "HTTP_403") {
    return "DICE didn't accept the token. Generate a new API token in MIO and connect again.";
  }
  if (r.status === 429) return "DICE is rate limiting Exos. The next sync will pick up where this one stopped.";
  if (r.error === "TIMEOUT") return "DICE took too long to answer. Try again in a minute.";
  if (r.error === "NETWORK" || r.status === 0) return "Exos couldn't reach DICE. Try again in a minute.";
  if (r.status >= 500) return "DICE had a problem answering. Try again later.";
  if (r.error === "GRAPHQL") return "DICE refused the request. Check that the token has access to your events.";
  return "DICE didn't answer as expected.";
}

// ---- The documents -----------------------------------------------------------
// Field names are DICE's, from its Ticket Holders API reference. Not asked
// for, on purpose (docs/dice-coverage.md): Fan.dob and every Address (Exos
// keeps no birthdays or postal addresses for fans), Order.event beyond its id.

export const FAN_FIELDS = "id firstName lastName email phoneNumber optInPartners";
const FEE_FIELDS = "category promoter dice";

export const TICKET_FIELDS = `fragment DiceTicket on Ticket {
  id code fullPrice commission diceCommission total
  fees { ${FEE_FIELDS} }
  holder { ${FAN_FIELDS} }
  ticketType { id name }
  seat { name }
  claimedAt
  priceTier { id name }
  fanSurveyAnswers { fanSurveyQuestion { title } value }
  extras { id code hasSeparateAccessBarcode product { id name } }
}`;

export const EVENT_FIELDS = `fragment DiceEvent on Event {
  id eventIdLive name state
  announceDatetime onSaleDatetime offSaleDatetime startDatetime endDatetime
  description hidden totalTicketAllocationQty currency url updatedAt
  artists { name }
  genreTypes genres
  images { type url }
  ticketTypes {
    id name description totalTicketAllocationQty archived faceValue price doorSalesPrice priceTierType
    priceTiers { id name allocation time faceValue price doorSalesPrice }
    externalSkus ticketPoolId
  }
  ticketPools { id name allocation }
  venues {
    id name type ageLimit displayedAddress streetAddress city state region country postalCode
    postOfficeBoxNumber latitude longitude timezoneName venueSpaces { id name }
  }
  venueSpace { id name }
  products { id name description totalAllocationQty archived faceValue externalSku }
  socialLinks { url campaign default }
  promoters
}`;

const page = (inner: string) => `totalCount pageInfo { endCursor hasNextPage } edges { node { ${inner} } }`;

export const VIEWER_QUERY = "query DiceViewer { viewer { id name } }";

export const EVENTS_QUERY = `query DiceEvents($first: Int!, $after: String, $where: EventWhereInput) {
  viewer { events(first: $first, after: $after, where: $where) { ${page("...DiceEvent")} } }
}
${EVENT_FIELDS}`;

export const TICKETS_QUERY = `query DiceTickets($first: Int!, $after: String, $where: TicketWhereInput) {
  viewer { tickets(first: $first, after: $after, where: $where) { ${page("...DiceTicket")} } }
}
${TICKET_FIELDS}`;

export const ORDERS_QUERY = `query DiceOrders($first: Int!, $after: String, $where: OrderWhereInput) {
  viewer { orders(first: $first, after: $after, where: $where) { ${page(`
    id purchasedAt quantity salesChannel fullPrice commission diceCommission total ipCity ipCountry
    fees { ${FEE_FIELDS} }
    event { id }
    fan { ${FAN_FIELDS} }
    tickets { ...DiceTicket }
    returns { id ticketId returnedAt reason }
    adjustments { reason processedAt ticket { id } feesChange { ${FEE_FIELDS} } }
    promoCode promoName promoDiscount promoType`)} } }
}
${TICKET_FIELDS}`;

export const RETURNS_QUERY = `query DiceReturns($first: Int!, $after: String, $where: ReturnWhereInput) {
  viewer { returns(first: $first, after: $after, where: $where) { ${page("id ticketId ticket { id } order { id } returnedAt reason")} } }
}`;

export const TRANSFERS_QUERY = `query DiceTransfers($first: Int!, $after: String, $where: TicketTransferWhereInput) {
  viewer { ticketTransfers(first: $first, after: $after, where: $where) { ${page("id transferredAt tickets { ...DiceTicket } orders { id }")} } }
}
${TICKET_FIELDS}`;

/**
 * The entities a sync reads, in order. `connection` is the Viewer field;
 * `since` is the date field of its where-input used for incremental passes
 * (null: DICE's TicketWhereInput has no date filter, so tickets are read in
 * full once and kept current by orders and transfers afterwards).
 */
export const ENTITIES = {
  events: { connection: "events", query: EVENTS_QUERY, since: "updatedAt" },
  tickets: { connection: "tickets", query: TICKETS_QUERY, since: null },
  orders: { connection: "orders", query: ORDERS_QUERY, since: "purchasedAt" },
  returns: { connection: "returns", query: RETURNS_QUERY, since: "returnedAt" },
  transfers: { connection: "ticketTransfers", query: TRANSFERS_QUERY, since: "transferredAt" },
} as const;
export type DiceEntity = keyof typeof ENTITIES;
export const ENTITY_ORDER: readonly DiceEntity[] = ["events", "tickets", "orders", "returns", "transfers"];

/** DICE's Datetime: ISO 8601 to the second, UTC. */
export function diceDatetime(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** The `where` for an incremental pass of an entity: `{field: {gte}}` from `since` minus the overlap; null for a full read. */
export function whereSince(entity: DiceEntity, since: string | null): Record<string, unknown> | null {
  const field = ENTITIES[entity].since;
  if (!field || !since) return null;
  const t = Date.parse(since);
  if (!Number.isFinite(t)) return null;
  return { [field]: { gte: diceDatetime(new Date(t - CURSOR_OVERLAP_MS)) } };
}

/** The variables of one page: `first` clamped to 1..50, `after` only when set, `where` only when set. */
export function pageVariables(first: number, after: string | null, where: Record<string, unknown> | null): Record<string, unknown> {
  const v: Record<string, unknown> = { first: Math.max(1, Math.min(MAX_PAGE_SIZE, Math.floor(first) || MAX_PAGE_SIZE)) };
  if (after) v.after = after;
  if (where) v.where = where;
  return v;
}

// ---- Pages -------------------------------------------------------------------

export interface DicePage {
  nodes: Record<string, unknown>[];
  endCursor: string | null;
  hasNextPage: boolean;
  totalCount: number | null;
  warnings: string[];
}

/** The connection inside a viewer answer, as a page. null when the shape is wrong. */
export function readConnection(data: unknown, connection: string): DicePage | null {
  const viewer = (data as { viewer?: Record<string, unknown> } | null)?.viewer;
  const conn = viewer?.[connection] as
    | { totalCount?: unknown; pageInfo?: { endCursor?: unknown; hasNextPage?: unknown }; edges?: unknown }
    | null | undefined;
  if (!conn || typeof conn !== "object" || !conn.pageInfo || typeof conn.pageInfo !== "object") return null;
  const edges = Array.isArray(conn.edges) ? conn.edges : [];
  const nodes = edges
    .map((e) => (e && typeof e === "object" ? (e as { node?: unknown }).node : null))
    .filter((x): x is Record<string, unknown> => !!x && typeof x === "object");
  const end = conn.pageInfo.endCursor;
  return {
    nodes,
    endCursor: typeof end === "string" && end.length > 0 && end.length <= 1000 ? end : null,
    hasNextPage: conn.pageInfo.hasNextPage === true,
    totalCount: typeof conn.totalCount === "number" && conn.totalCount >= 0 ? conn.totalCount : null,
    warnings: [],
  };
}

export interface PageLimits {
  /** Page size (`first`), at most 50. */
  first?: number;
  /** Hard cap on pages read for this entity in this run. */
  maxPages: number;
  /** Hard cap on rows read for this entity in this run. */
  maxRows: number;
  /** Stop starting new pages after this wall-clock time (ms since epoch). */
  deadline?: number;
  now?: () => number;
}

export type PageOutcome =
  | { ok: true; page: DicePage }
  | { ok: false; status: number; error: string; warnings: string[] };

/**
 * Reads pages of one entity from `after` on, handing each to `onPage`
 * (which may write it and save the cursor) before asking for the next.
 * Stops at the end, at a cap (pages, rows, deadline), or on an error.
 * `done` is true only when DICE said there is no next page.
 */
export async function readPages(
  opts: DiceOptions, token: string, entity: DiceEntity, start: { after: string | null; since: string | null },
  limits: PageLimits, onPage: (p: DicePage) => Promise<void> | void,
): Promise<{ done: boolean; pages: number; rows: number; after: string | null; error?: { status: number; error: string }; capped?: string }> {
  const { query, connection } = ENTITIES[entity];
  const where = whereSince(entity, start.since);
  const now = limits.now ?? Date.now;
  let after = start.after;
  let pages = 0;
  let rows = 0;
  for (;;) {
    if (pages >= limits.maxPages) return { done: false, pages, rows, after, capped: "pages" };
    if (rows >= limits.maxRows) return { done: false, pages, rows, after, capped: "rows" };
    if (limits.deadline !== undefined && now() >= limits.deadline) return { done: false, pages, rows, after, capped: "time" };
    const first = Math.min(limits.first ?? MAX_PAGE_SIZE, MAX_PAGE_SIZE, limits.maxRows - rows);
    const r = await diceQuery<unknown>(opts, token, query, pageVariables(first, after, where));
    if (!r.ok) return { done: false, pages, rows, after, error: { status: r.status, error: r.error ?? "GRAPHQL" } };
    const p = readConnection(r.data, connection);
    if (!p) return { done: false, pages, rows, after, error: { status: r.status, error: "BAD_RESPONSE" } };
    p.warnings = r.warnings;
    pages++;
    rows += p.nodes.length;
    await onPage(p);
    if (!p.hasNextPage) return { done: true, pages, rows, after: null };
    if (!p.endCursor || p.endCursor === after) {
      // DICE says there is more but gave no new cursor: stop rather than loop.
      return { done: false, pages, rows, after, error: { status: 200, error: "BAD_CURSOR" } };
    }
    after = p.endCursor;
  }
}

/** Checks a token with the smallest query there is. */
export async function readViewer(opts: DiceOptions, token: string): Promise<DiceResult<{ id: string; name: string | null }>> {
  const r = await diceQuery<{ viewer?: { id?: unknown; name?: unknown } }>(opts, token, VIEWER_QUERY);
  if (!r.ok) return { ...r, data: null };
  const v = r.data?.viewer;
  if (!v || (typeof v.id !== "string" && typeof v.id !== "number")) {
    return { ok: false, status: r.status, data: null, error: "BAD_RESPONSE", warnings: r.warnings, attempts: r.attempts };
  }
  return { ...r, data: { id: String(v.id).slice(0, 200), name: typeof v.name === "string" ? v.name.slice(0, 120) : null } };
}
