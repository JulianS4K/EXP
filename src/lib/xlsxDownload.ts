// The XLSX buttons' one entry point (claude/exos-attendance-report). The
// writer (./xlsx.ts) is loaded with a dynamic import on the first click, so
// it stays out of every page's first load; then the download is logged as
// export.run (exos_audit_export, mig 20261113120000), best effort like the
// CSV exports: a failed log never holds the file back.

import type { XlsxSheet } from './xlsx';
import { logExport } from './orgAuditApi';
import type { ExportKind } from './orgAudit';

export interface XlsxLog {
  orgId?: string | null;
  eventId?: string | null;
  kind: ExportKind;
}

/** Build and download a workbook, then log it. Rows counted: every data row (headers left out). */
export async function saveXlsx(fileParts: Array<string | undefined | null>, sheets: XlsxSheet[], log: XlsxLog): Promise<void> {
  const { downloadXlsx, xlsxFileName } = await import('./xlsx');
  downloadXlsx(xlsxFileName(fileParts), sheets);
  const rows = sheets.reduce((n, s) => n + s.rows.length, 0);
  await logExport(log.orgId ?? null, log.kind, rows, log.eventId ?? null);
}
