// One DICE sync run (exos-dice-import, exos-api): read each entity's pages
// from where the last run stopped and hand them to the database
// (exos_dice_apply), or, for a dry run, only count them. Pure TypeScript
// with the reads and the writes injected, so vitest drives it with fakes
// (src/lib/diceClient.test.ts).
//
// Order: events -> tickets -> orders -> returns -> transfers. Events go
// first because a ticket from viewer.tickets names only its ticket type,
// and the ticket type's event comes from the events pass. Nothing after
// events runs until the events pass is complete.
//
// Per entity the connection keeps { since, after, pass_started_at }
// (exos_dice_connections.cursors):
//   since            the start of the last COMPLETE pass: the next pass reads
//                    only what changed since (where: updatedAt / purchasedAt /
//                    returnedAt / transferredAt gte since minus 5 minutes).
//                    NULL: a full read.
//   after            DICE's endCursor inside a pass that a cap stopped; the
//                    next run resumes there.
//   pass_started_at  when the running pass started; it becomes `since` once
//                    the pass completes.
// The SQL moves these in the same transaction as the page's rows, so a run
// that dies resumes at the last page it wrote. Tickets have no date filter
// in DICE (TicketWhereInput), so viewer.tickets is read in full once; after
// that new tickets arrive through orders and new holders through transfers.

import {
  type DiceEntity, type DiceOptions, ENTITY_ORDER, type PageLimits, readPages,
} from "./client.ts";
import { type DiceRow, type EventRow, fansIn, isUpcomingEvent, mapNodes, marketingConsent } from "./map.ts";

export interface EntityCursor { since: string | null; after: string | null; pass_started_at: string | null }
export type Cursors = Partial<Record<DiceEntity, EntityCursor>>;

export interface PageWrite {
  /** DICE's endCursor when another page follows, else null. */
  after: string | null;
  /** True on the pass's last page. */
  done: boolean;
  pass_started_at: string;
}

export interface SyncStore {
  /** Writes one page of rows and the entity's cursor; answers the page's counts. */
  apply(entity: DiceEntity, rows: DiceRow[], page: PageWrite): Promise<Record<string, number>>;
}

export interface SyncLimits {
  /** Pages per entity per run (each at most 50 rows). */
  maxPagesPerEntity: number;
  /** Rows per run, all entities together. */
  maxRowsPerRun: number;
  /** Wall-clock budget: no page starts after it (ms since epoch). */
  deadline: number;
}

export const RUN_LIMITS: SyncLimits = { maxPagesPerEntity: 40, maxRowsPerRun: 5000, deadline: 0 };
export const DRY_RUN_LIMITS: SyncLimits = { maxPagesPerEntity: 4, maxRowsPerRun: 1000, deadline: 0 };

export interface EntityReport {
  read: number;
  pages: number;
  /** DICE's totalCount on the first page read (everything matching, not just this run). */
  total: number | null;
  done: boolean;
  skipped?: string;
  capped?: string;
  counts: Record<string, number>;
}

export interface SyncReport {
  status: "ok" | "partial" | "error";
  dry_run: boolean;
  kind: "full" | "incremental";
  entities: Partial<Record<DiceEntity, EntityReport>>;
  /** Dry run: what the pages read would bring in. */
  preview?: {
    events_upcoming: number; events_past: number; ticket_types: number; tickets: number;
    fans: number; fans_marketing_consent: number; orders: number; returns: number; transfers: number;
  };
  error?: { entity: DiceEntity; status: number; error: string };
  warnings: string[];
}

const add = (into: Record<string, number>, from: Record<string, number>) => {
  for (const [k, v] of Object.entries(from)) if (typeof v === "number" && Number.isFinite(v)) into[k] = (into[k] ?? 0) + v;
};

/** full when no entity has completed a pass yet. */
export function runKind(c: Cursors): "full" | "incremental" {
  return ENTITY_ORDER.every((e) => c[e]?.since) ? "incremental" : "full";
}

/**
 * Runs one sync. `store` null is a DRY RUN: the same reads, nothing written,
 * cursors untouched, and a preview of what an import would bring in.
 */
export async function runSync(
  opts: DiceOptions, token: string, cursors: Cursors, store: SyncStore | null, limits: SyncLimits,
  now: () => number = Date.now,
): Promise<SyncReport> {
  const dry = store === null;
  const report: SyncReport = { status: "ok", dry_run: dry, kind: runKind(cursors), entities: {}, warnings: [] };
  const fanEmails = new Map<string, boolean>();
  const preview = {
    events_upcoming: 0, events_past: 0, ticket_types: 0, tickets: 0, fans: 0, fans_marketing_consent: 0,
    orders: 0, returns: 0, transfers: 0,
  };
  let rowsLeft = limits.maxRowsPerRun;
  let eventsDone = !!cursors.events?.since;

  for (const entity of ENTITY_ORDER) {
    const cur: EntityCursor = cursors[entity] ?? { since: null, after: null, pass_started_at: null };
    const rep: EntityReport = { read: 0, pages: 0, total: null, done: false, counts: {} };
    report.entities[entity] = rep;
    if (entity === "tickets" && cur.since) {
      rep.done = true;
      rep.skipped = "kept current by orders and transfers";
      continue;
    }
    if (entity !== "events" && !eventsDone && !dry) {
      rep.skipped = "waiting for the events pass";
      report.status = "partial";
      continue;
    }
    if (rowsLeft <= 0 || now() >= limits.deadline) {
      rep.skipped = "run budget";
      report.status = "partial";
      continue;
    }
    // A dry run always starts a pass from the top (it saves no cursor).
    const start = dry ? { after: null, since: cur.since } : { after: cur.after, since: cur.since };
    const passStarted = (!dry && cur.after && cur.pass_started_at) || new Date(now()).toISOString();
    const pageLimits: PageLimits = {
      maxPages: limits.maxPagesPerEntity, maxRows: rowsLeft, deadline: limits.deadline, now,
    };
    const res = await readPages(opts, token, entity, start, pageLimits, async (p) => {
      if (rep.total === null) rep.total = p.totalCount;
      for (const w of p.warnings) if (report.warnings.length < 10) report.warnings.push(`${entity}: ${w}`);
      const rows = mapNodes(entity, p.nodes);
      rep.read += rows.length;
      if (dry) {
        tally(entity, rows, preview, fanEmails, new Date(now()));
        return;
      }
      add(rep.counts, await store!.apply(entity, rows, { after: p.hasNextPage ? p.endCursor : null, done: !p.hasNextPage, pass_started_at: passStarted }));
    });
    rep.pages = res.pages;
    rowsLeft -= res.rows;
    if (res.error) {
      report.error = { entity, status: res.error.status, error: res.error.error };
      report.status = "error";
      break;
    }
    rep.done = res.done;
    if (!res.done) {
      rep.capped = res.capped;
      report.status = "partial";
      if (!dry) break; // the next run resumes this entity first
    }
    if (entity === "events" && res.done) eventsDone = true;
  }
  if (dry) {
    preview.fans = fanEmails.size;
    preview.fans_marketing_consent = [...fanEmails.values()].filter(Boolean).length;
    report.preview = preview;
  }
  return report;
}

function tally(
  entity: DiceEntity, rows: DiceRow[], p: NonNullable<SyncReport["preview"]>, fans: Map<string, boolean>, now: Date,
) {
  if (entity === "events") {
    for (const e of rows as EventRow[]) {
      if (isUpcomingEvent(e, now)) p.events_upcoming++;
      else p.events_past++;
      p.ticket_types += e.ticket_types.length;
    }
  } else if (entity === "tickets") p.tickets += rows.length;
  else if (entity === "orders") p.orders += rows.length;
  else if (entity === "returns") p.returns += rows.length;
  else p.transfers += rows.length;
  for (const f of fansIn(entity, rows)) {
    if (!f.email) continue;
    // One consenting record is enough for the preview; the import applies the
    // rule per record, and a later "false" withdraws a DICE-sourced consent.
    fans.set(f.email, (fans.get(f.email) ?? false) || marketingConsent(f));
  }
}

// ---- The switch and the API body (pure, so vitest checks them) -------------

export const DICE_DISABLED_MESSAGE =
  "Import from DICE is switched off on this Exos install (EXOS_DICE_IMPORT). Ask the operator to turn it on.";

/** EXOS_DICE_IMPORT=on, read from the injected env getter. Anything else is off. */
export function diceImportEnabled(env: (k: string) => string | undefined): boolean {
  return (env("EXOS_DICE_IMPORT") ?? "").trim().toLowerCase() === "on";
}

/** The body POST /v1/dice-import/sync takes; null when fine. */
export function diceSyncBodyProblem(b: Record<string, unknown>): string | null {
  const extra = Object.keys(b).find((k) => k !== "dry_run");
  if (extra) return `unknown field ${extra.slice(0, 60)}`;
  if ("dry_run" in b && typeof b.dry_run !== "boolean") return "dry_run must be true or false";
  return null;
}
