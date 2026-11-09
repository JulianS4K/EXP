// Checkout conversion by in-app browser (mig 20261105140000): the event
// report's "Where buyers checked out" table. docs/gtm-nyc.md's success
// metric is checkout conversion inside Instagram's browser within 10% of a
// real browser; this is where an organizer (and we) can read it.
//
// exos_event_in_app_report answers one row per (in_app_browser, escaped_from):
// checkouts started, paid, tickets and gross. Pure summarising here, so it
// tests without Supabase; the read is at the bottom.

import { supabase } from './supabase';
import { IN_APP_LABEL, sanitizeInAppKind, sanitizeInAppRecord, type InAppKind, type InAppRecord } from './inAppBrowser';

export interface InAppReportRow {
  in_app_browser: InAppRecord | null;
  escaped_from: InAppKind | null;
  started: number;
  paid: number;
  tickets: number;
  gross_cents: number;
}

export interface InAppLine {
  key: string;
  label: string;
  /** 'app' = inside an in-app browser; 'escaped' = opened in the browser from one; 'browser'; 'unknown' = not recorded. */
  group: 'app' | 'escaped' | 'browser' | 'unknown';
  started: number;
  paid: number;
  tickets: number;
  grossCents: number;
  /** paid / started, 0..1; null with nothing started. */
  conversion: number | null;
}

export interface InAppSummary {
  lines: InAppLine[];
  /** Everything inside in-app browsers vs real browsers (escapes count as browser). */
  inApp: { started: number; paid: number; conversion: number | null };
  browser: { started: number; paid: number; conversion: number | null };
  /** In-app conversion relative to the browser's (0.9 = 10% lower); null if either is unknown. */
  ratio: number | null;
  /** Share of paid gross that came from in-app traffic (inside, or escaped from one). */
  inAppGrossShare: number | null;
  currency: string;
}

const conv = (paid: number, started: number) => (started > 0 ? paid / started : null);

export function parseInAppReport(raw: unknown): { rows: InAppReportRow[]; currency: string } {
  const o = (raw && typeof raw === 'object' ? raw : {}) as { rows?: unknown; currency?: unknown };
  const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : Number(v) || 0);
  const rows = (Array.isArray(o.rows) ? o.rows : []).map((r) => {
    const x = (r ?? {}) as Record<string, unknown>;
    return {
      in_app_browser: sanitizeInAppRecord(x.in_app_browser) ?? null,
      escaped_from: sanitizeInAppKind(x.escaped_from) ?? null,
      started: n(x.started), paid: n(x.paid), tickets: n(x.tickets), gross_cents: n(x.gross_cents),
    };
  });
  return { rows, currency: typeof o.currency === 'string' ? o.currency.toUpperCase() : 'USD' };
}

export function summarizeInApp(rows: InAppReportRow[], currency = 'USD'): InAppSummary {
  const lines = new Map<string, InAppLine>();
  const add = (key: string, label: string, group: InAppLine['group'], r: InAppReportRow) => {
    const l = lines.get(key) ?? { key, label, group, started: 0, paid: 0, tickets: 0, grossCents: 0, conversion: null };
    l.started += r.started; l.paid += r.paid; l.tickets += r.tickets; l.grossCents += r.gross_cents;
    lines.set(key, l);
  };
  for (const r of rows) {
    const kind = r.in_app_browser;
    if (kind && kind !== 'none') {
      add(kind, kind === 'webview' ? 'Other in-app browser' : `${IN_APP_LABEL[kind]} app`, 'app', r);
    } else if (kind === 'none' && r.escaped_from) {
      const from = r.escaped_from === 'webview' ? 'another app' : IN_APP_LABEL[r.escaped_from];
      add(`escaped:${r.escaped_from}`, `Browser, opened from ${from}`, 'escaped', r);
    } else if (kind === 'none') {
      add('browser', 'Browser', 'browser', r);
    } else {
      add('unknown', 'Not recorded', 'unknown', r);
    }
  }
  const out = [...lines.values()].map((l) => ({ ...l, conversion: conv(l.paid, l.started) }));
  const order = { app: 0, escaped: 1, browser: 2, unknown: 3 } as const;
  out.sort((a, b) => order[a.group] - order[b.group] || b.started - a.started || a.label.localeCompare(b.label));
  const sum = (groups: InAppLine['group'][]) => out.filter((l) => groups.includes(l.group))
    .reduce((t, l) => ({ started: t.started + l.started, paid: t.paid + l.paid, gross: t.gross + l.grossCents }), { started: 0, paid: 0, gross: 0 });
  const inApp = sum(['app']);
  const browser = sum(['escaped', 'browser']);
  const fromApps = sum(['app', 'escaped']);
  const allGross = sum(['app', 'escaped', 'browser', 'unknown']).gross;
  const ci = conv(inApp.paid, inApp.started);
  const cb = conv(browser.paid, browser.started);
  return {
    lines: out,
    inApp: { started: inApp.started, paid: inApp.paid, conversion: ci },
    browser: { started: browser.started, paid: browser.paid, conversion: cb },
    ratio: ci !== null && cb !== null && cb > 0 ? ci / cb : null,
    inAppGrossShare: allGross > 0 ? fromApps.gross / allGross : null,
    currency,
  };
}

export function pct(v: number | null): string {
  return v === null ? '–' : `${Math.round(v * 100)}%`;
}

/** The event's breakdown, or null before the migration / when the caller can't read it. */
export async function getInAppReport(eventId: string): Promise<InAppSummary | null> {
  const { data, error } = await supabase.rpc('exos_event_in_app_report', { p_event_id: eventId });
  if (error) {
    if (error.code !== 'PGRST202') console.warn('in-app report unavailable (non-fatal):', error.message);
    return null;
  }
  const { rows, currency } = parseInAppReport(data);
  return summarizeInApp(rows, currency);
}
