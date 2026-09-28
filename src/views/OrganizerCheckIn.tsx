import { AccessNeedBadges } from '../components/Accessibility';
import React, { useState, useEffect, useRef } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { getEventForEdit, getPublicEvent } from '../lib/events';
import {
  getTicketForScan,
  listEventTicketsForRegistry,
  checkInTicket,
  checkInOffline,
  undoCheckIn,
  recordScanReject,
  countEventCheckins,
  setCheckinTestWindow,
  syncServerClock,
  type CheckInResult,
  type ScanTicket,
} from '../lib/tickets';
import { Ticket, Event } from '../types';
import { Search, CheckCircle2, XCircle, ArrowLeft, Loader2, User, Camera, ScanLine, Download, Wifi, WifiOff, RefreshCw } from 'lucide-react';
import { motion, AnimatePresence } from 'motion/react';
// html5-qrcode (~330KB) is loaded on demand when the scanner opens, so it
// never ships on other routes or before the camera is actually needed.
import type { Html5Qrcode } from 'html5-qrcode';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { verifyBarcode, extractTicketIdFromAny, type VerifyResult } from '../lib/barcode';
import { describeSkew, serverNow } from '../lib/serverClock';
import {
  deviceLabel,
  enqueueScan,
  isRegistryFresh,
  newClientRef,
  parseQueue,
  removeRefs,
  type QueuedScan,
} from '../lib/offlineCheckins';
import { isFullTicketId, rosterMatches } from '../lib/doorSearch';
import { joinCheckinChannel } from '../lib/checkinChannel';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';
import ScanRejectAudit from '../components/ScanRejectAudit';
import GuestListDoor from '../components/GuestListDoor';
import {
  getDoorExtras,
  loadCachedDoorExtras,
  loadPendingArrivals,
  pruneStaleDoorExtras,
  saveCachedDoorExtras,
  type DoorExtras,
} from '../lib/guestListsApi';
import { overlayPending } from '../lib/guestLists';
import { indexTablesByTicket, tableSummary } from '../lib/tables';

// The cached roster holds every ticket's barcode secret, so it is dropped
// 24 hours after it was downloaded (REGISTRY_TTL_MS, lib/offlineCheckins).
// A multi-day event re-downloads it each day; opening the page online does
// that automatically.

interface OfflineTicketEntry {
  used: boolean;
  voided?: boolean;
  name: string;
  tier: string;
  ownerId?: string;
  barcodeSecret?: string;
  promoterId?: string;
  // Pending-transfer lock. When set, the ticket is mid-flight to a
  // receiver and the offline scan path refuses entry. Picked up on
  // each registry refresh so the lock propagates within a refresh
  // cycle even when the door staff is fully offline-cached.
  pendingTransferId?: string | null;
}

interface StoredRegistry {
  _savedAt: number;
  data: Record<string, OfflineTicketEntry>;
}

function saveRegistry(eventId: string, data: StoredRegistry['data']) {
  const payload: StoredRegistry = { _savedAt: Date.now(), data };
  localStorage.setItem(`registry_${eventId}`, JSON.stringify(payload));
}

function pruneStaleCheckInCaches() {
  const now = Date.now();
  // Queued offline scans (pending_updates_*) are NOT dropped with their
  // roster: they replay on their own, and the server answers for them.
  const toDelete: string[] = [];
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (!key || !key.startsWith('registry_')) continue;
    try {
      const raw = localStorage.getItem(key);
      if (!raw) continue;
      const parsed = JSON.parse(raw);
      // Legacy entries (no _savedAt wrapper) are old-format and considered
      // stale by definition — they predate this hygiene pass.
      if (!parsed || typeof parsed !== 'object' || !isRegistryFresh(parsed._savedAt, now)) {
        toDelete.push(key);
      }
    } catch {
      toDelete.push(key);
    }
  }
  for (const k of toDelete) localStorage.removeItem(k);
}

function savePending(eventId: string | undefined, queue: QueuedScan[]) {
  if (!eventId) return;
  try {
    localStorage.setItem(`pending_updates_${eventId}`, JSON.stringify(queue));
  } catch {
    /* storage full / blocked: the in-memory queue still replays this session */
  }
}

// Door copy for server refusals that aren't barcode problems.
const REFUSAL_TEXT: Record<string, string> = {
  'needs-manager': 'Needs a manager. Typing a ticket in (no live code) is an override only an owner or manager can make.',
  'reason-required': 'Give a reason for the override (at least 3 characters).',
  'not-assigned': "You're not assigned to scan this event. Ask an owner or manager to add it to your events.",
  'bad-scan-time': 'This offline scan is too old to upload (more than 24 hours).',
};

type ScanRow = { key: string; ticketId: string; name: string; time: Date; status: 'SUCCESS' | 'DENIED' | 'UNDONE' };

export default function OrganizerCheckIn() {
  const { eventId } = useParams();
  const navigate = useNavigate();
  const { user, isAdmin } = useAuth();
  const { orgs } = useOrganization();
  const { toast } = useToast();
  const [event, setEvent] = useState<Event | null>(null);
  const [searchId, setSearchId] = useState('');
  const [status, setStatus] = useState<'idle' | 'searching' | 'success' | 'not-found' | 'already-used' | 'invalid-barcode' | 'needs-reason'>('idle');
  // "Already used": when (and on which device) the ticket was checked in.
  const [usedInfo, setUsedInfo] = useState<{ at?: string; device?: string } | null>(null);
  // A typed override waiting for its reason (owner / manager only).
  const [overrideFor, setOverrideFor] = useState<{ ticketId: string; name: string } | null>(null);
  const [overrideReason, setOverrideReason] = useState('');
  // Undo a check-in from the scan log.
  const [undoKey, setUndoKey] = useState<string | null>(null);
  const [undoReason, setUndoReason] = useState('');
  const [undoing, setUndoing] = useState(false);
  // A scan during the pre-doors test window: verified, but the ticket stays
  // unused (the server answers reason 'test-scan'), so don't mark it locally.
  const [testScan, setTestScan] = useState(false);
  // Reason text shown in the 'invalid-barcode' state — populated by the
  // HMAC verifier so the operator knows whether the issue was a stale
  // barcode (screenshot from earlier) or a forged one.
  const [invalidReason, setInvalidReason] = useState<string>('');
  // Set when a check-in is refused because doors aren't open yet — surfaces an
  // owner/manager "enable test scanning" control (RPC is server-gated).
  const [doorsBlocked, setDoorsBlocked] = useState(false);
  const [enablingTest, setEnablingTest] = useState(false);
  const [foundTicket, setFoundTicket] = useState<Ticket | null>(null);
  // True when the last lookup was typed or picked from the name search
  // rather than a scanned signed QR — nothing was cryptographically verified.
  const [manualEntry, setManualEntry] = useState(false);
  const verdictRef = useRef<HTMLDivElement>(null);
  // On a phone the verdict renders below the scanner; bring it into view.
  useEffect(() => {
    if (status === 'idle' || status === 'searching') return;
    verdictRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }, [status, foundTicket?.id]);
  const [buyerName, setBuyerName] = useState<string>('');
  const [scanning, setScanning] = useState(false);
  const [isOffline, setIsOffline] = useState(!navigator.onLine);
  const [offlineRegistry, setOfflineRegistry] = useState<Record<string, OfflineTicketEntry>>({});
  const [downloading, setDownloading] = useState(false);
  const [syncing, setSyncing] = useState(false);
  const [pendingUpdates, setPendingUpdates] = useState<QueuedScan[]>([]);
  const [recentScans, setRecentScans] = useState<ScanRow[]>([]);
  // This scanner's label, recorded on each check-in ("already used at Door 7F3A").
  const device = React.useMemo(() => {
    try {
      return deviceLabel(window.localStorage);
    } catch {
      return deviceLabel(null);
    }
  }, []);
  // Role in the event's org — a hint for the UI; the server enforces it.
  const doorRole = orgs.find((o) => o.org.id === event?.orgId)?.membership.role ?? null;
  const canOverride = isAdmin || doorRole === 'owner' || doorRole === 'manager';
  // "Inside venue" = tickets actually scanned in (exos_event_checkins count),
  // NOT tickets sold. Seeded on mount; refreshed by the realtime channel below
  // as scans land (this lane + others).
  const [insideVenue, setInsideVenue] = useState(0);
  const scannerRef = useRef<Html5Qrcode | null>(null);
  // Holds the setTimeout ID for the deferred camera start so stopScanner()
  // can cancel a pending start that hasn't fired yet. Without this, if
  // stopScanner is called within the 50ms window, scannerRef.current is still
  // null (timeout hasn't run) so stopScanner is a no-op, then the timeout
  // fires and starts the camera with no owner to shut it down.
  const startScannerTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasOfflineRef = useRef(isOffline);
  // Door mode: ticket scanning, or the guest-list name search (mig 20260926050000).
  const [mode, setMode] = useState<'tickets' | 'guests'>('tickets');
  // Offline door download: table labels by ticket + every guest-list entry.
  const [doorExtras, setDoorExtras] = useState<DoorExtras | null>(null);
  const [extrasSyncing, setExtrasSyncing] = useState(false);
  const tableByTicket = React.useMemo(() => indexTablesByTicket(doorExtras?.tables ?? []), [doorExtras]);

  const updateDoorExtras = (next: DoorExtras) => {
    setDoorExtras(next);
    if (eventId) saveCachedDoorExtras(eventId, next);
  };

  // Best-effort: a failure here never blocks ticket check-in.
  const downloadDoorExtras = async (opts: { silent?: boolean } = {}) => {
    if (!eventId || !user) return;
    setExtrasSyncing(true);
    try {
      const fresh = await getDoorExtras(eventId);
      // Arrivals still waiting to sync stay applied on top of the fresh copy.
      updateDoorExtras({ ...fresh, guests: overlayPending(fresh.guests, loadPendingArrivals(eventId)) });
      if (!opts.silent && mode === 'guests') {
        toast({ kind: 'success', message: `Synced ${fresh.guests.length} guest-list name(s) for offline check-in.` });
      }
    } catch (err) {
      console.warn('door extras (tables / guest lists) unavailable:', err);
      if (!opts.silent && mode === 'guests') toast({ kind: 'error', message: 'Failed to sync guest lists.' });
    } finally {
      setExtrasSyncing(false);
    }
  };

  useEffect(() => {
    async function fetchEvent() {
      if (!eventId) return;
      try {
        // Staff RLS on exos_events lets door staff read the event (any status).
        const ev = await getEventForEdit(eventId);
        if (ev) setEvent(ev);
      } catch (err) {
        console.error('Failed to load event for check-in:', err);
      }
    }
    fetchEvent();

    const handleSyncStatus = () => setIsOffline(!navigator.onLine);
    window.addEventListener('online', handleSyncStatus);
    window.addEventListener('offline', handleSyncStatus);

    // Sweep stale offline-check-in caches from previous events.
    //
    // We tag each registry payload with `_savedAt` and prune anything older
    // than 7 days on mount. Without this, every event the organizer checks
    // attendees in for accumulates ~one entry per attendee in localStorage
    // forever and eventually trips the ~5MB browser quota.
    pruneStaleCheckInCaches();
    pruneStaleDoorExtras();

    // Load registry and pending updates for THIS event, if cached.
    if (eventId) {
      const saved = localStorage.getItem(`registry_${eventId}`);
      if (saved) {
        try {
          const parsed = JSON.parse(saved);
          // Older payloads were stored as plain Record<id, entry>; newer ones
          // wrap the data in `{ _savedAt, data }`. Handle both shapes.
          if (parsed && typeof parsed === 'object' && parsed.data) {
            setOfflineRegistry(parsed.data);
          } else {
            setOfflineRegistry(parsed);
          }
        } catch {
          // Corrupt cache — drop it.
          localStorage.removeItem(`registry_${eventId}`);
        }
      }
      setDoorExtras(loadCachedDoorExtras(eventId));
      // Queued offline scans (older builds stored bare ids; parseQueue
      // upgrades them to typed entries, which the server treats as overrides).
      // Saved back so an upgraded entry keeps its ref across reloads.
      const queued = parseQueue(localStorage.getItem(`pending_updates_${eventId}`), serverNow());
      setPendingUpdates(queued);
      if (queued.length > 0) savePending(eventId, queued);
    }
    // Measure this device's clock against the server (offline scans record the
    // corrected time, and the local code check uses it).
    void syncServerClock();

    return () => {
      window.removeEventListener('online', handleSyncStatus);
      window.removeEventListener('offline', handleSyncStatus);
      void stopScanner();
    };
  }, [eventId]);

  useEffect(() => {
    if (!isOffline && pendingUpdates.length > 0) {
      syncPendingUpdates();
    }
  }, [isOffline, pendingUpdates.length]);

  const syncPendingUpdates = async () => {
    if (pendingUpdates.length === 0 || syncing || !eventId) return;
    setSyncing(true);
    const answered: string[] = [];
    const conflicts: { id: string; reason: string }[] = [];
    try {
      // Per-item try/catch so one failing replay doesn't abort the rest of the
      // queue. Each scan replays with the code it read and when
      // (exos_check_in_offline): the server re-checks the signature against the
      // ticket's current owner + secret, so a ticket transferred after the
      // roster sync comes back as a conflict. The same ref twice counts once,
      // so a retry after a lost response is safe. Only a network / auth error
      // throws and keeps the scan queued.
      for (const scan of pendingUpdates) {
        try {
          const result = await checkInOffline(scan, eventId, device);
          // The server logs refusals to the scan report itself.
          if (!result.ok) conflicts.push({ id: scan.ticketId, reason: result.reason ?? 'unknown' });
          answered.push(scan.ref);
        } catch (err) {
          console.error(`Error syncing offline scan ${scan.ref}:`, err);
        }
      }
    } finally {
      // Functional update: scans queued while this ran must not be lost.
      setPendingUpdates((prev) => {
        const remaining = removeRefs(prev, answered);
        savePending(eventId, remaining);
        return remaining;
      });
      setSyncing(false);
      if (conflicts.length > 0) {
        toast({
          kind: 'error',
          message: `${conflicts.length} ticket(s) admitted while offline were refused on sync (${[...new Set(conflicts.map((c) => c.reason))].join(', ')}). Check the scan report.`,
        });
      }
    }
  };

  // Tear down the live camera scanner safely. stop() rejects if the camera
  // isn't actively running, so guard on state and swallow that case.
  const stopScanner = async () => {
    // Cancel any pending deferred start so the camera doesn't open after we
    // shut down (the 50ms timeout may not have fired yet when stopScanner is
    // called, e.g. on unmount or stop-button tap).
    if (startScannerTimeoutRef.current !== null) {
      clearTimeout(startScannerTimeoutRef.current);
      startScannerTimeoutRef.current = null;
    }
    const s = scannerRef.current;
    scannerRef.current = null;
    if (!s) return;
    try {
      if (s.isScanning) await s.stop();
    } catch {
      /* not scanning / already stopped */
    }
    try {
      s.clear();
    } catch {
      /* element already torn down */
    }
  };

  const startScanner = () => {
    setScanning(true);
    setStatus('idle');

    // Defer one tick so the #reader container is in the DOM, then open the
    // back camera DIRECTLY (facingMode: environment). The previous
    // Html5QrcodeScanner widget required a second "Request Camera / Start"
    // tap that often never activated the camera on phones, and its fixed
    // 250px qrbox threw on narrow viewports (video < box) — both fixed here.
    startScannerTimeoutRef.current = setTimeout(async () => {
      startScannerTimeoutRef.current = null;
      try {
        const { Html5Qrcode } = await import('html5-qrcode');
        const html5Qr = new Html5Qrcode('reader');
        scannerRef.current = html5Qr;
        await html5Qr.start(
          { facingMode: 'environment' },
          {
            fps: 10,
            // Responsive box: 70% of the smaller video dimension, so it
            // never exceeds the camera frame on small phones.
            qrbox: (vw: number, vh: number) => {
              const m = Math.floor(Math.min(vw, vh) * 0.7);
              return { width: m, height: m };
            },
          },
          (decodedText: string) => {
            setSearchId(decodedText);
            handleCheckIn(undefined, decodedText);
            void stopScanner();
            setScanning(false);
          },
          () => {
            /* per-frame decode miss — ignore */
          },
        );
      } catch (err) {
        console.error('Camera start failed:', err);
        toast({
          kind: 'error',
          message:
            'Could not open the camera. Allow camera access for this site in your browser settings, or type the ticket ID below to check in.',
        });
        scannerRef.current = null;
        setScanning(false);
      }
    }, 50);
  };

  /**
   * Build a CSV from the in-memory offline registry and trigger a browser
   * download. We deliberately don't refetch — the registry
   * already represents what the organizer cares about (ticket id, attendee
   * name, tier, used/unused). For a richer export with email/checkInDate
   * the organizer can extend this.
   */
  const exportAttendeesCsv = async () => {
    let entries = Object.entries(offlineRegistry);
    // Auto-sync if the operator hits Export before they've ever
    // downloaded the registry. Skip if we're offline (downloadRegistry
    // would just fail) — in that case the toast tells them what to do.
    if (entries.length === 0) {
      if (isOffline) {
        toast({
          kind: 'info',
          message: 'No registry data — connect to the network and sync first.',
        });
        return;
      }
      toast({ kind: 'info', message: 'Syncing attendees first…' });
      await downloadRegistry();
      // Re-read state after the sync. We can't rely on closure-captured
      // offlineRegistry — pull from localStorage which the sync just
      // wrote, then fall through to the CSV build.
      try {
        const raw = localStorage.getItem(`registry_${eventId}`);
        if (raw) {
          const parsed = JSON.parse(raw);
          const data = (parsed && parsed.data) || parsed;
          entries = Object.entries(data);
        }
      } catch {
        /* ignore — we'll just fall through to "no entries" */
      }
      if (entries.length === 0) {
        toast({ kind: 'warn', message: 'No attendees to export yet.' });
        return;
      }
    }
    const rows = entries.map(([id, raw]) => {
      // `Object.entries` widens our typed Record values to `unknown`; cast
      // back to the row shape we put in.
      const e = raw as OfflineTicketEntry;
      return [id, e.name, e.tier, e.voided ? 'voided' : e.used ? 'used' : 'active', e.promoterId || ''];
    });
    // Shared builder (lib/csv): RFC 4180 quoting + formula-injection guard.
    downloadCsv(
      csvFileName(['attendees', event?.title ?? eventId]),
      toCsv(['ticket_id', 'attendee', 'tier', 'status', 'promoter'], rows),
    );

    toast({ kind: 'success', message: `Exported ${rows.length} attendee(s).` });
  };

  const downloadRegistry = async (opts: { silent?: boolean } = {}) => {
    if (!eventId || !user) return;
    const silent = opts.silent === true;
    if (!silent) setDownloading(true);
    try {
      // listEventTicketsForRegistry resolves owner display names + carries the
      // per-ticket barcode_secret (staff RLS) so the offline HMAC check works.
      const entries = await listEventTicketsForRegistry(eventId);
      const registry: Record<string, OfflineTicketEntry> = {};
      for (const e of entries) {
        registry[e.id] = {
          used: e.status === 'used',
          voided: e.status === 'voided',
          name: e.name,
          tier: e.tier,
          ownerId: e.ownerId,
          barcodeSecret: e.barcodeSecret,
          promoterId: e.promoterId,
          pendingTransferId: e.pendingTransferId,
        };
      }

      setOfflineRegistry(registry);
      saveRegistry(eventId, registry);
      void downloadDoorExtras({ silent: true });
      if (!silent) {
        toast({
          kind: 'success',
          message: `Synced ${entries.length} ticket(s) for offline check-in.`,
        });
      }
    } catch (err) {
      console.error(err);
      if (!silent) toast({ kind: 'error', message: 'Failed to sync offline registry.' });
    } finally {
      if (!silent) setDownloading(false);
    }
  };

  // Shared-lock (D4-OPS-10): subscribe to other lanes' check-ins for this event
  // and mark those tickets used locally, so a near-simultaneous scan here is
  // refused. Authoritative + RLS-gated (org staff only) via postgres_changes.
  useEffect(() => {
    if (!eventId) return undefined;
    const ch = joinCheckinChannel(eventId, (ticketId) => {
      setOfflineRegistry((prev) => {
        const entry = prev[ticketId];
        if (!entry || entry.used) return prev; // unknown ticket or already used
        const next = { ...prev, [ticketId]: { ...entry, used: true } };
        saveRegistry(eventId, next);
        return next;
      });
      // A check-in landed (this lane or another) — bump the live count by one
      // rather than re-running a count(*) per scan. A count(*) per realtime tick
      // per lane doesn't scale at a busy multi-lane gate; postgres_changes emits
      // exactly one event per check-in row (incl. our own), so +1 is accurate.
      // Reconciled against the authoritative head-count on reconnect below.
      setInsideVenue((n) => n + 1);
    });
    return () => ch.leave();
  }, [eventId]);

  // Seed "inside venue" on mount (the realtime channel keeps it live after).
  useEffect(() => {
    if (!eventId) return undefined;
    let cancelled = false;
    countEventCheckins(eventId)
      .then((n) => { if (!cancelled) setInsideVenue(n); })
      .catch(() => {/* non-fatal */});
    return () => { cancelled = true; };
  }, [eventId]);

  // Pull the roster once on open (silently) so name search works without a
  // manual download; the cached copy from localStorage covers offline opens.
  useEffect(() => {
    if (!eventId || !user || !navigator.onLine) return;
    void downloadRegistry({ silent: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [eventId, user?.uid]);

  // On reconnect, re-pull the registry: Realtime doesn't replay check-ins other
  // lanes made while we were offline, so catch up silently once links return.
  useEffect(() => {
    if (wasOfflineRef.current && !isOffline) {
      void downloadRegistry({ silent: true });
      // Realtime doesn't replay check-ins that landed while we were
      // disconnected, so reconcile the live count against the authoritative
      // head-count once (the only count(*) on this path — not per scan).
      if (eventId) countEventCheckins(eventId).then(setInsideVenue).catch(() => {});
    }
    wasOfflineRef.current = isOffline;
  }, [isOffline]);

  // Write an audit entry every time we refuse a scan. Organizers
  // see these on the event report — useful for door-staff debugging
  // ("which ticket id keeps getting rejected?") AND for spotting
  // patterns of abuse (broker buying tickets to event_A and
  // attempting to walk into event_B in a refund-then-resell loop).
  // Best-effort: a write failure here logs but doesn't change UI.
  const writeScanReject = async (
    reason:
      | 'wrong-event'
      | 'voided'
      | 'used'
      | 'in-transfer'
      | 'invalid-barcode'
      | 'not-found'
      | 'expired-code',
    source: 'camera' | 'manual',
    ctx: {
      ticketIdAttempted?: string | null;
      wrongEventId?: string;
      wrongEventTitle?: string;
      reasonDetail?: string;
    } = {},
  ) => {
    if (!eventId || !user) return;
    try {
      await recordScanReject({
        eventId,
        orgId: event?.orgId || '',
        reason,
        source,
        ticketIdAttempted: ctx.ticketIdAttempted ?? null,
        wrongEventId: ctx.wrongEventId ?? null,
        wrongEventTitle: ctx.wrongEventTitle ?? null,
        reasonDetail: ctx.reasonDetail ?? null,
      });
    } catch (err) {
      console.warn('scanReject audit write failed (non-fatal):', err);
    }
  };

  const pushScan = (ticketId: string, name: string, scanStatus: ScanRow['status']) =>
    setRecentScans((prev) =>
      [{ key: newClientRef(), ticketId, name: name || '—', time: new Date(), status: scanStatus }, ...prev].slice(0, 8),
    );

  const queueScan = (scan: QueuedScan) =>
    setPendingUpdates((prev) => {
      const next = enqueueScan(prev, scan);
      savePending(eventId, next);
      return next;
    });

  const markLocal = (ticketId: string, patch: Partial<OfflineTicketEntry>) =>
    setOfflineRegistry((prev) => {
      const entry = prev[ticketId];
      if (!entry) return prev;
      const next = { ...prev, [ticketId]: { ...entry, ...patch } };
      if (eventId) saveRegistry(eventId, next);
      return next;
    });

  // Why the local signature check refused a code. A correctly signed code from
  // the wrong time window is a clock problem (or a screenshot): say by how much.
  const localRejectText = (v: VerifyResult, now: number): string => {
    if (v.reason === 'bucket-expired' && v.signatureValid && v.bucket != null) return describeSkew(v.bucket, now);
    const reasonText: Record<string, string> = {
      'malformed': 'Could not read this code.',
      'bad-bucket': 'Code is malformed.',
      'bucket-expired': 'This code expired. Ask the attendee to refresh their ticket and rescan.',
      'signature-mismatch':
        "Signature didn't match this ticket — a screenshot, a tampered code, or a ticket transferred since the offline list was downloaded (re-download it).",
      'legacy-no-secret':
        'This is an old-format ticket. Ask the attendee to open the app and refresh their ticket, then rescan.',
    };
    return reasonText[v.reason || ''] || 'Code rejected.';
  };

  const denyLocal = (ticketId: string, name: string, v: VerifyResult, src: 'camera' | 'manual') => {
    setStatus('invalid-barcode');
    setInvalidReason(localRejectText(v, serverNow()));
    pushScan(ticketId, name, 'DENIED');
    void writeScanReject(v.reason === 'bucket-expired' ? 'expired-code' : 'invalid-barcode', src, {
      ticketIdAttempted: ticketId,
      reasonDetail: v.reason || undefined,
    });
  };

  // A server refusal (online check-in).
  const showRefusal = (result: CheckInResult, ticketId: string, name: string, src: 'camera' | 'manual') => {
    setBuyerName(name);
    if (result.reason === 'reason-required') {
      // We always ask first; if the server still wants one, ask again.
      setOverrideFor({ ticketId, name });
      setStatus('needs-reason');
      return;
    }
    pushScan(ticketId, name, 'DENIED');
    if (result.reason === 'used') {
      setUsedInfo({ at: result.check_in_at, device: result.device });
      markLocal(ticketId, { used: true });
      setStatus('already-used');
      void writeScanReject('used', src, { ticketIdAttempted: ticketId });
      return;
    }
    if (result.reason === 'voided') markLocal(ticketId, { voided: true });
    const text: Record<string, string> = {
      ...REFUSAL_TEXT,
      'barcode-expired': 'This code expired. Ask the attendee to refresh their ticket and rescan.',
      'barcode-rejected':
        "Signature didn't match this ticket (server check) — a screenshot, a tampered code, or a ticket transferred since the offline list was downloaded.",
      'doors-not-open': 'Doors are not open yet for this event. Check-in opens at the event’s doors time.',
      'voided':
        'This ticket was refunded. The holder should not be admitted with this ticket. Direct them to event support if there is a dispute.',
      'in-transfer':
        'This ticket is mid-transfer. Ask the holder to either cancel the transfer or have the recipient claim it before scanning.',
      'wrong-event': 'This ticket is for a different event.',
      'event-cancelled': 'This event was cancelled. Nobody can be checked in.',
    };
    setStatus('invalid-barcode');
    setInvalidReason(text[result.reason] || 'The server did not accept this ticket. Re-download the offline list and retry.');
    if (result.reason === 'doors-not-open') {
      setDoorsBlocked(true);
      return;
    }
    if (result.reason === 'needs-manager') return;
    const audit =
      result.reason === 'barcode-expired' ? 'expired-code'
      : result.reason === 'barcode-rejected' ? 'invalid-barcode'
      : result.reason === 'voided' || result.reason === 'in-transfer' || result.reason === 'wrong-event' ? result.reason
      : 'not-found';
    void writeScanReject(audit, src, { ticketIdAttempted: ticketId, reasonDetail: result.reason });
  };

  const admitted = (ticket: Ticket, name: string, test: boolean) => {
    setTestScan(test);
    setBuyerName(name || 'Anonymous attendee');
    setFoundTicket(ticket);
    if (!test) {
      pushScan(ticket.id, name, 'SUCCESS');
      markLocal(ticket.id, { used: true });
    }
    setStatus('success');
    setSearchId('');
    setOverrideFor(null);
  };

  const handleCheckIn = async (e?: React.FormEvent, manualValue?: string, reason?: string) => {
    if (e) e.preventDefault();
    const probeValue = (manualValue || searchId).trim();
    if (!probeValue || !eventId) return;
    const src: 'camera' | 'manual' = scanning ? 'camera' : 'manual';
    // A typed ticket id (no signed code). A CAMERA scan is never treated as
    // one: a scanned bare UUID is a forgery downgrade and fails the signature
    // check (and the server refuses it).
    const isBareManualEntry = !scanning && !probeValue.startsWith('T-') && !probeValue.includes(':');

    setStatus('searching');
    setManualEntry(isBareManualEntry);
    setFoundTicket(null);
    setInvalidReason('');
    setDoorsBlocked(false);
    setUsedInfo(null);
    setTestScan(false);

    // The ticket id inside the QR payload (signed 4-segment, legacy, or bare).
    const docId = extractTicketIdFromAny(probeValue) || probeValue;
    // Ticket ids are UUIDs — anything over 128 chars can't be one.
    if (!docId || docId.length > 128) {
      setStatus('not-found');
      return;
    }
    const cached = offlineRegistry[docId];

    // Typed override: owner / manager, with a reason (the server enforces both;
    // this only saves a round trip).
    if (isBareManualEntry && !reason) {
      setBuyerName(cached?.name || '');
      if (!canOverride) {
        setStatus('invalid-barcode');
        setInvalidReason(REFUSAL_TEXT['needs-manager']);
        return;
      }
      setOverrideFor({ ticketId: docId, name: cached?.name || '' });
      setOverrideReason('');
      setStatus('needs-reason');
      return;
    }

    if (cached) {
      // Local checks against the downloaded list: a fast fail online, and all
      // there is offline. The signature is checked on the server-corrected clock.
      if (cached.barcodeSecret && !isBareManualEntry) {
        const verify = await verifyBarcode(probeValue, cached.barcodeSecret, { now: serverNow() });
        if (!verify.ok) {
          setBuyerName(cached.name);
          denyLocal(docId, cached.name, verify, src);
          return;
        }
      }
      if (cached.pendingTransferId || cached.voided) {
        setStatus('invalid-barcode');
        setInvalidReason(
          cached.voided
            ? 'This ticket was refunded. The holder should not be admitted with this ticket. Direct them to event support if there is a dispute.'
            : 'This ticket is mid-transfer. Ask the holder to either cancel the transfer or have the recipient claim it before scanning.',
        );
        setBuyerName(cached.name);
        pushScan(docId, cached.name, 'DENIED');
        void writeScanReject(cached.voided ? 'voided' : 'in-transfer', src, { ticketIdAttempted: docId });
        return;
      }
      if (cached.used && isOffline) {
        // Online, the server answers with when it was used (below).
        setStatus('already-used');
        setBuyerName(cached.name);
        pushScan(docId, cached.name, 'DENIED');
        void writeScanReject('used', src, { ticketIdAttempted: docId });
        return;
      }

      const localTicket = { id: docId, tierName: cached.tier } as Ticket;
      if (!isOffline) {
        try {
          const result = await checkInTicket(
            docId, src, isBareManualEntry ? 'manual' : 'verified',
            isBareManualEntry ? undefined : probeValue, eventId, { reason, device },
          );
          if (!result.ok) {
            showRefusal(result, docId, cached.name, src);
            return;
          }
          admitted(localTicket, cached.name, result.reason === 'test-scan');
          return;
        } catch (err) {
          console.error('Server check-in failed; admitting on the offline list and queuing the scan.', err);
        }
      }
      // Offline (or the server was unreachable): admit on the downloaded list
      // and queue the scan WITH its code and time. The upload re-checks the
      // signature server-side, so a ticket transferred since the download
      // comes back as a conflict.
      queueScan({
        ref: newClientRef(),
        ticketId: docId,
        payload: isBareManualEntry ? null : probeValue,
        scannedAt: serverNow(),
        source: src,
        ...(reason ? { reason } : {}),
      });
      admitted(localTicket, cached.name, false);
      return;
    }

    // Not on the downloaded list and offline: we can neither verify the ticket
    // nor record the reject until the link returns.
    if (isOffline) {
      setStatus('not-found');
      return;
    }

    try {
      // Staff-gated read. null when the ticket doesn't exist OR the caller
      // isn't staff of its org — both are "not a valid ticket for this door".
      const scanTicket = await getTicketForScan(docId);
      if (!scanTicket) {
        setStatus('not-found');
        void writeScanReject('not-found', src, { ticketIdAttempted: docId });
        return;
      }

      // Wrong event: best-effort title of the other event so staff can route the holder.
      if (scanTicket.eventId !== eventId) {
        let otherTitle: string | undefined;
        try {
          const otherEvent = await getPublicEvent(scanTicket.eventId);
          otherTitle = otherEvent?.title;
        } catch {
          /* draft / private event — generic copy */
        }
        setStatus('invalid-barcode');
        setInvalidReason(
          otherTitle
            ? `Wrong event — this ticket is for "${otherTitle}". Direct the holder to that event's door.`
            : 'Wrong event — this ticket belongs to a different event. Direct the holder to the correct door.',
        );
        pushScan(docId, '—', 'DENIED');
        void writeScanReject('wrong-event', src, {
          ticketIdAttempted: docId,
          wrongEventId: scanTicket.eventId,
          wrongEventTitle: otherTitle,
        });
        return;
      }

      // Local signature check (fast fail) when we could read the secret; the
      // server re-checks it either way.
      if (!isBareManualEntry && scanTicket.barcodeSecret) {
        const verify = await verifyBarcode(probeValue, scanTicket.barcodeSecret, { now: serverNow() });
        if (!verify.ok) {
          setFoundTicket(scanTicket);
          setBuyerName(scanTicket.ownerName);
          denyLocal(scanTicket.id, scanTicket.ownerName, verify, src);
          return;
        }
      }

      const result = await checkInTicket(
        scanTicket.id, src, isBareManualEntry ? 'manual' : 'verified',
        isBareManualEntry ? undefined : probeValue, eventId, { reason, device },
      );
      setFoundTicket(scanTicket);
      if (!result.ok) {
        showRefusal(result, scanTicket.id, scanTicket.ownerName, src);
        return;
      }
      admitted(scanTicket, scanTicket.ownerName, result.reason === 'test-scan');
    } catch (error) {
      console.error(error);
      setStatus('not-found');
    }
  };

  const submitOverride = (e: React.FormEvent) => {
    e.preventDefault();
    const why = overrideReason.trim();
    if (!overrideFor || why.length < 3) return;
    void handleCheckIn(undefined, overrideFor.ticketId, why);
  };

  // Undo a check-in from the scan log (owner / manager, with a reason).
  const confirmUndo = async (row: ScanRow) => {
    if (!eventId) return;
    const why = undoReason.trim();
    if (why.length < 3) return;
    const finish = (message: string) => {
      setRecentScans((prev) => prev.map((r) => (r.key === row.key ? { ...r, status: 'UNDONE' } : r)));
      markLocal(row.ticketId, { used: false });
      setUndoKey(null);
      setUndoReason('');
      toast({ kind: 'success', message });
    };
    // Still waiting to upload: just drop it from the queue.
    const queued = pendingUpdates.find((q) => q.ticketId === row.ticketId);
    if (queued) {
      setPendingUpdates((prev) => {
        const next = removeRefs(prev, [queued.ref]);
        savePending(eventId, next);
        return next;
      });
      finish('Check-in removed before upload.');
      return;
    }
    setUndoing(true);
    try {
      const result = await undoCheckIn(row.ticketId, eventId, why);
      if (!result.ok) {
        toast({
          kind: 'error',
          message:
            REFUSAL_TEXT[result.reason] ??
            (result.reason === 'not-checked-in' ? 'That ticket is not checked in.' : 'Could not undo that check-in.'),
        });
        return;
      }
      setInsideVenue((n) => Math.max(0, n - 1));
      finish('Check-in undone. The ticket can be scanned again.');
    } catch (err) {
      console.error('undo check-in failed', err);
      toast({ kind: 'error', message: 'Could not undo that check-in (network).' });
    } finally {
      setUndoing(false);
    }
  };

  // Owner/manager: open a bounded test-scanning window so the doors gate is
  // lifted for early scanner testing. Auto-expires (no left-on-forever). The RPC
  // rejects non-owner/manager callers, so it's safe to offer here.
  const enableTestWindow = async () => {
    if (!eventId) return;
    setEnablingTest(true);
    try {
      await setCheckinTestWindow(eventId, 3);
      setDoorsBlocked(false);
      setStatus('idle');
      setInvalidReason('');
      toast({ kind: 'success', message: 'Test scanning enabled for 3 hours. Remember it lifts the doors gate.' });
    } catch (err) {
      console.error('enable test window failed', err);
      toast({ kind: 'error', message: 'Could not enable test scanning — owner/manager only.' });
    } finally {
      setEnablingTest(false);
    }
  };

  if (!event) return null;

  const rejectCount = recentScans.filter((s) => s.status === 'DENIED').length;

  return (
    <div className="bg-[#f2f4f7] min-h-screen">
    <div className="max-w-7xl mx-auto px-4 py-10">
      <style>{`
        @keyframes checkinScanline { 0% { top: 8%; } 100% { top: 92%; } }
        .checkin-scanline { animation: checkinScanline 2s ease-in-out infinite alternate; }
      `}</style>

      <button onClick={() => navigate('/dashboard')} className="flex items-center gap-2 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-colors">
        <ArrowLeft className="w-3.5 h-3.5" />
        Back to dashboard
      </button>

      <div className="flex flex-col md:flex-row md:items-end justify-between gap-4 mb-8">
        <div>
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Door Check-In</p>
          <span className="inline-flex items-baseline gap-3 flex-wrap">
            <h1 className="text-3xl md:text-4xl font-bold tracking-tight text-slate-900">{event.title}</h1>
            <span className="marker text-brand-secondary text-lg rotate-[-3deg] leading-none whitespace-nowrap">at the door ✦</span>
          </span>
        </div>
        <div className="flex flex-wrap items-center gap-2">
           <div className={`flex items-center space-x-2 px-3 py-2 rounded text-[10px] font-black uppercase tracking-widest ${isOffline ? 'bg-red-50 text-red-500 border border-red-200' : 'bg-emerald-50 text-emerald-500 border border-emerald-200'}`}>
              {isOffline ? <WifiOff className="w-3 h-3" /> : <Wifi className="w-3 h-3" />}
              <span>{isOffline ? 'Offline' : 'Online'}</span>
           </div>
           <button
             onClick={() => downloadRegistry()}
             disabled={downloading}
             className="flex items-center space-x-2 px-3 py-2 bg-slate-900 text-white rounded text-[10px] font-black uppercase tracking-widest hover:bg-slate-800 transition-all disabled:opacity-50"
           >
              <Download className={`w-3 h-3 ${downloading ? 'animate-bounce' : ''}`} aria-hidden="true" />
              <span>{downloading ? 'Downloading…' : 'Download for offline'}</span>
           </button>
           <button
             type="button"
             onClick={exportAttendeesCsv}
             aria-label="Export attendees as CSV"
             className="flex items-center space-x-2 px-3 py-2 bg-white text-slate-900 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest hover:bg-slate-50 transition-all shadow-sm"
           >
              <Download className="w-3 h-3" aria-hidden="true" />
              <span>Export CSV</span>
           </button>
        </div>
      </div>

      {pendingUpdates.length > 0 && (
         <div className="mb-6 flex flex-wrap items-center gap-3 bg-amber-50 border border-amber-200 rounded-lg px-4 py-2.5">
           <div className="text-[11px] font-bold text-amber-700 uppercase tracking-widest">
             {pendingUpdates.length} check-in{pendingUpdates.length === 1 ? '' : 's'} waiting to upload
           </div>
           {!isOffline && (
             <button
               onClick={syncPendingUpdates}
               disabled={syncing}
               className="flex items-center text-[10px] font-black text-slate-700 bg-white border border-slate-200 hover:bg-slate-50 px-3 py-1.5 rounded transition-all uppercase tracking-widest disabled:opacity-50"
             >
               <RefreshCw className={`w-3 h-3 mr-2 ${syncing ? 'animate-spin' : ''}`} />
               Upload now
             </button>
           )}
         </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* SCANNER STAGE */}
        <div className="lg:col-span-2 space-y-6">
      <div className="inline-flex p-1 bg-slate-100 rounded-xl" role="tablist" aria-label="Door mode">
        {(['tickets', 'guests'] as const).map((m) => (
          <button
            key={m}
            type="button"
            role="tab"
            aria-selected={mode === m}
            onClick={() => {
              if (m === 'guests' && scanning) {
                void stopScanner();
                setScanning(false);
              }
              setMode(m);
            }}
            className={`px-4 py-2 rounded-lg text-[10px] font-black uppercase tracking-widest transition-all ${mode === m ? 'bg-white text-slate-900 shadow-sm' : 'text-slate-500 hover:text-slate-900'}`}
          >
            {m === 'tickets' ? 'Tickets' : `Guest list${doorExtras ? ` (${doorExtras.guests.length})` : ''}`}
          </button>
        ))}
      </div>
      {mode === 'guests' && eventId ? (
      <div className="bg-white p-6 md:p-8 rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
        <GuestListDoor
          eventId={eventId}
          isOffline={isOffline}
          extras={doorExtras}
          onExtrasChange={updateDoorExtras}
          onSync={() => void downloadDoorExtras()}
          syncing={extrasSyncing}
        />
      </div>
      ) : (
      <div className="bg-white p-6 md:p-8 rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
        {scanning ? (
           <div className="relative mb-2">
              <div className="relative rounded-2xl overflow-hidden bg-black border border-slate-800">
                <div id="reader" className="w-full overflow-hidden"></div>
                {/* punk reticle + scanline overlay */}
                <div className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-56 h-56 max-w-[70%] max-h-[70%]">
                  <div className="absolute -top-1 -left-1 w-10 h-10 border-t-4 border-l-4 border-brand-primary"></div>
                  <div className="absolute -top-1 -right-1 w-10 h-10 border-t-4 border-r-4 border-brand-primary"></div>
                  <div className="absolute -bottom-1 -left-1 w-10 h-10 border-b-4 border-l-4 border-brand-primary"></div>
                  <div className="absolute -bottom-1 -right-1 w-10 h-10 border-b-4 border-r-4 border-brand-primary"></div>
                  <div className="checkin-scanline absolute left-2 right-2 h-0.5 bg-brand-primary shadow-[0_0_12px_#00FF00]"></div>
                </div>
                <div className="pointer-events-none absolute top-4 left-4 flex items-center gap-2 text-[10px] font-black uppercase tracking-widest text-white/80">
                  <span className="w-2 h-2 bg-brand-primary rounded-full animate-ping"></span> Scanning…
                </div>
                <div className="pointer-events-none absolute bottom-4 left-0 right-0 text-center type text-[11px] uppercase tracking-widest text-white/40">point camera at the rotating QR pass</div>
              </div>
              <button
                onClick={() => {
                  void stopScanner();
                  setScanning(false);
                }}
                aria-label="Stop the QR code scanner"
                className="mt-4 w-full py-4 text-[10px] font-bold uppercase tracking-widest text-slate-400 hover:text-slate-900 transition-colors"
              >
                Abort Scanning
              </button>
           </div>
        ) : (
          <div className="flex flex-col space-y-4 mb-2">
             <button
               onClick={startScanner}
               className="w-full bg-slate-900 hover:bg-black text-white rounded-2xl py-8 flex flex-col items-center justify-center transition-all border border-slate-800"
             >
                <ScanLine className="w-8 h-8 mb-2 text-brand-primary" />
                <span className="disp text-2xl tracking-wide">OPEN CAMERA SCANNER</span>
             </button>

             <div className="relative">
                <div className="absolute inset-0 flex items-center"><div className="w-full border-t border-slate-100"></div></div>
                <div className="relative flex justify-center text-[9px] uppercase font-bold tracking-widest text-slate-300"><span className="bg-white px-4">Manual Entry — no camera?</span></div>
             </div>

             <form
               onSubmit={(e) => {
                 // A name / id-tail search with exactly one match admits that
                 // ticket; several matches wait for staff to pick from the list.
                 if (!isFullTicketId(searchId)) {
                   e.preventDefault();
                   const m = rosterMatches<OfflineTicketEntry>(offlineRegistry, searchId);
                   if (m.length === 1 && !m[0][1].used && !m[0][1].voided) {
                     setSearchId('');
                     void handleCheckIn(undefined, m[0][0]);
                   }
                   return;
                 }
                 void handleCheckIn(e);
               }}
               className="relative"
             >
                <input
                  type="text"
                  placeholder="Name, last 6 of pass ID, or full ID"
                  aria-label="Search by name or pass ID"
                  autoComplete="off"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-5 pl-14 pr-24 text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-tm-blue transition-all"
                  value={searchId}
                  onChange={(e) => setSearchId(e.target.value)}
                />
                <Search className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-5 h-5" />
                <button
                  type="submit"
                  className="absolute right-4 top-1/2 -translate-y-1/2 bg-slate-900 text-white px-4 py-2 rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-800 transition-colors"
                >
                  Check
                </button>
             </form>
             {(() => {
               const matches = rosterMatches<OfflineTicketEntry>(offlineRegistry, searchId);
               if (searchId.trim().length < 2 || isFullTicketId(searchId)) return null;
               if (Object.keys(offlineRegistry).length === 0) {
                 return <p className="text-xs text-slate-500 px-2">Tap “Download for offline” to search by name.</p>;
               }
               if (matches.length === 0) {
                 return <p className="text-xs text-slate-500 px-2">No one on the list matches “{searchId.trim()}”.</p>;
               }
               return (
                 <ul className="divide-y divide-slate-100 border border-slate-200 rounded-2xl overflow-hidden" aria-label="Matching tickets">
                   {matches.map(([id, entry]) => (
                     <li key={id} className="flex items-center gap-3 px-4 py-3">
                       <div className="min-w-0 flex-1">
                         <p className="font-bold text-slate-900 text-sm truncate">{entry.name || 'Unnamed'}</p>
                         <p className="text-[11px] text-slate-500 truncate">{entry.tier} · …{id.slice(-6)}</p>
                         {(doorExtras?.ticketAccess?.[id]?.length ?? 0) > 0 && (
                           <div className="mt-1"><AccessNeedBadges needs={doorExtras!.ticketAccess![id]} /></div>
                         )}
                       </div>
                       {entry.voided ? (
                         <span className="text-[10px] font-black uppercase tracking-widest text-red-500">Void</span>
                       ) : entry.used ? (
                         <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">In</span>
                       ) : canOverride ? (
                         // Admitting by name is a typed override: asks for a reason.
                         <button
                           type="button"
                           onClick={() => { setSearchId(''); void handleCheckIn(undefined, id); }}
                           className="px-4 py-2.5 bg-green-600 text-white rounded-xl text-[11px] font-black uppercase tracking-widest hover:bg-green-700"
                         >
                           Admit…
                         </button>
                       ) : (
                         <span className="text-[10px] font-black uppercase tracking-widest text-slate-400" title="Scan their live code, or ask a manager to override">
                           Scan code
                         </span>
                       )}
                     </li>
                   ))}
                 </ul>
               );
             })()}
          </div>
        )}

        <div ref={verdictRef} className="scroll-mt-24" />
        <AnimatePresence mode="wait">
          {status === 'searching' && (
            <motion.div 
              key="searching"
              initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
              className="flex flex-col items-center justify-center py-10"
            >
              <Loader2 className="w-12 h-12 text-brand-primary animate-spin mb-4" />
              <p className="text-slate-400 font-bold uppercase tracking-widest text-xs">Verifying Ticket...</p>
            </motion.div>
          )}

          {status === 'success' && foundTicket && (
            <motion.div 
              key="success"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-green-50/50 p-8 rounded-[2.5rem] border border-green-100 flex flex-col items-center text-center"
            >
              <div className="w-20 h-20 bg-green-500 rounded-full flex items-center justify-center text-white mb-6 shadow-lg shadow-green-200">
                 <CheckCircle2 className="w-10 h-10" />
              </div>
              <h2 className="text-2xl font-bold text-green-900 mb-1 leading-none uppercase tracking-tight">{testScan ? 'Test scan OK' : 'Entry Allowed'}</h2>
              <p className="text-green-600 font-bold uppercase tracking-widest text-[10px] mb-6">
                {testScan ? 'Valid ticket · not checked in (test window)' : manualEntry ? 'Manual entry · check ID if unsure' : 'Pass verified'}
              </p>

              {(doorExtras?.ticketAccess?.[foundTicket.id]?.length ?? 0) > 0 && (
                <div role="note" className="w-full mb-4 p-4 rounded-2xl bg-sky-50 border border-sky-200 text-left">
                  <p className="text-[11px] font-black uppercase tracking-widest text-sky-800 mb-2">Access needs</p>
                  <AccessNeedBadges needs={doorExtras!.ticketAccess![foundTicket.id]} />
                </div>
              )}

              <div className="w-full space-y-4">
                 <div className="flex items-center justify-between p-4 bg-white rounded-2xl border border-green-50">
                    <div className="flex items-center space-x-3 text-left">
                       <User className="text-green-500 w-5 h-5" />
                       <div>
                          <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-none mb-1">Attendee</p>
                          <p className="font-bold text-slate-900">{buyerName}</p>
                       </div>
                    </div>
                 </div>
                 <div className="p-4 bg-white rounded-2xl border border-green-50 text-left">
                    <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-none mb-1">Ticket Type</p>
                    <p className="font-bold text-slate-900">{foundTicket.tierName || 'Standard Admission'}</p>
                 </div>
                 {tableByTicket[foundTicket.id] && (() => {
                   const tb = tableByTicket[foundTicket.id];
                   return (
                     <div className="p-4 bg-white rounded-2xl border border-green-50 text-left">
                       <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-none mb-1">Table</p>
                       <p className="font-bold text-slate-900">{tb.label || 'Not assigned yet'}</p>
                       <p className="text-xs text-slate-500 mt-1">
                         {tableSummary({ partySize: tb.partySize, minSpendCents: tb.minSpendCents, sectionLabel: tb.sectionLabel }, event?.currency || 'USD')}
                       </p>
                     </div>
                   );
                 })()}
              </div>
            </motion.div>
          )}

          {status === 'needs-reason' && overrideFor && (
            <motion.div
              key="needs-reason"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-sky-50/60 p-8 rounded-[2.5rem] border border-sky-200 flex flex-col items-center text-center"
            >
              <h2 className="text-2xl font-bold text-sky-900 mb-1 leading-none uppercase tracking-tight">Manual override</h2>
              <p className="text-sky-700 font-bold uppercase tracking-widest text-[10px] mb-4">
                No live code was scanned{overrideFor.name ? ` · ${overrideFor.name}` : ''} · …{overrideFor.ticketId.slice(-6)}
              </p>
              <p className="text-slate-600 text-sm mb-4 max-w-sm">
                Check the holder's ID. The reason is saved with the check-in and shows in the scan report.
              </p>
              <form onSubmit={submitOverride} className="w-full max-w-sm space-y-3">
                <input
                  type="text"
                  value={overrideReason}
                  onChange={(e) => setOverrideReason(e.target.value)}
                  placeholder="Reason, e.g. phone died — checked photo ID"
                  aria-label="Reason for the override"
                  maxLength={300}
                  autoFocus
                  className="w-full bg-white border border-sky-200 rounded-xl px-4 py-3 text-sm text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-400"
                />
                <div className="flex gap-2">
                  <button
                    type="submit"
                    disabled={overrideReason.trim().length < 3}
                    className="flex-1 px-4 py-3 bg-slate-900 text-white rounded-xl text-[11px] font-black uppercase tracking-widest hover:bg-black disabled:opacity-40"
                  >
                    Admit with override
                  </button>
                  <button
                    type="button"
                    onClick={() => { setOverrideFor(null); setStatus('idle'); }}
                    className="px-4 py-3 bg-white border border-slate-200 text-slate-700 rounded-xl text-[11px] font-black uppercase tracking-widest hover:bg-slate-50"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            </motion.div>
          )}

          {status === 'already-used' && (
            <motion.div 
              key="already-used"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-orange-50/50 p-8 rounded-[2.5rem] border border-orange-100 flex flex-col items-center text-center"
            >
              <div className="w-20 h-20 bg-orange-500 rounded-full flex items-center justify-center text-white mb-6 shadow-lg shadow-orange-200">
                 <XCircle className="w-10 h-10" />
              </div>
              <h2 className="text-2xl font-bold text-orange-900 mb-1 leading-none uppercase tracking-tight">Already Used</h2>
              <p className="text-orange-600 font-bold uppercase tracking-widest text-[10px] mb-6">Ticket already checked in</p>
              
              <p className="text-slate-500 text-sm font-medium mb-4">
                Checked in at: <br />
                <strong>
                  {usedInfo?.at
                    ? new Date(usedInfo.at).toLocaleString()
                    : foundTicket?.checkInDate && foundTicket.checkInDate.toMillis() > 0
                    ? foundTicket.checkInDate.toDate().toLocaleString()
                    : 'Earlier (time shows once online)'}
                </strong>
                {usedInfo?.device ? <><br />on <strong>{usedInfo.device}</strong></> : null}
              </p>
              
              <div className="w-full p-4 bg-white rounded-2xl border border-orange-100 text-left">
                 <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-none mb-1">Attendee Name</p>
                 <p className="font-bold text-slate-900">{buyerName}</p>
              </div>
            </motion.div>
          )}

          {status === 'not-found' && (
            <motion.div
              key="not-found"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-red-50/50 p-8 rounded-[2.5rem] border border-red-100 flex flex-col items-center text-center relative"
            >
              <div className="w-20 h-20 bg-red-500 rounded-full flex items-center justify-center text-white mb-6 shadow-lg shadow-red-200">
                 <XCircle className="w-10 h-10" aria-hidden="true" />
              </div>
              <h2 className="text-2xl font-bold text-red-900 mb-1 leading-none uppercase tracking-tight">Invalid Ticket</h2>
              <p className="text-red-600 font-bold uppercase tracking-widest text-[10px] mb-6">Ticket not found or invalid for this event</p>

              {/*
                NOTE: A "Force Admit Pass" button used to live here. It pushed
                whatever value the operator had typed into the search box into
                pendingUpdates and then later flushed it to Firestore as
                status:'used'. With the rules tightened, that update would be
                rejected for any ticket the organizer doesn't own — but the
                button itself was a footgun for laundering tickets and a great
                way for an operator to invalidate the wrong ID by accident.
                The right answer is a verified rescan, not a manual override.
              */}
            </motion.div>
          )}

          {status === 'invalid-barcode' && (
            <motion.div
              key="invalid-barcode"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-amber-50/50 p-8 rounded-[2.5rem] border border-amber-200 flex flex-col items-center text-center"
            >
              <div className="w-20 h-20 bg-amber-500 rounded-full flex items-center justify-center text-white mb-6 shadow-lg shadow-amber-200">
                 <XCircle className="w-10 h-10" aria-hidden="true" />
              </div>
              <h2 className="text-2xl font-bold text-amber-900 mb-1 leading-none uppercase tracking-tight">Code Rejected</h2>
              <p className="text-amber-700 font-bold uppercase tracking-widest text-[10px] mb-4">
                {invalidReason || 'Signature did not match — possible screenshot or stale code.'}
              </p>
              {doorsBlocked ? (
                <button
                  type="button"
                  onClick={enableTestWindow}
                  disabled={enablingTest}
                  className="mt-2 px-4 py-2 bg-amber-600 hover:bg-amber-700 text-white rounded-xl text-[10px] font-black uppercase tracking-widest transition-colors disabled:opacity-50"
                >
                  {enablingTest ? 'Enabling…' : 'Enable test scanning (3h)'}
                </button>
              ) : (
                <p className="text-amber-600 text-[11px] font-medium mb-2">
                  Ask the attendee to open their ticket and rescan the live QR.
                </p>
              )}
            </motion.div>
          )}
        </AnimatePresence>
      </div>
      )}
        </div>

        {/* SIDEBAR: stats + scan log */}
        <div className="space-y-6">
          <div className="grid grid-cols-3 gap-3">
            <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 text-center">
              <p className="disp text-3xl tracking-tight text-green-600" style={{ transform: 'skewX(-3deg)' }}>{insideVenue}</p>
              <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mt-1">In</p>
            </div>
            <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 text-center">
              <p className="disp text-3xl tracking-tight text-slate-900" style={{ transform: 'skewX(-3deg)' }}>{event.totalTickets}</p>
              <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mt-1">Sold</p>
            </div>
            <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 text-center">
              <p className="disp text-3xl tracking-tight text-rose-500" style={{ transform: 'skewX(-3deg)' }}>{rejectCount}</p>
              <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mt-1">Rejects</p>
            </div>
          </div>

          <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
            <div className="px-5 py-4 border-b border-slate-100 flex items-center justify-between">
              <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest">Scan log</h2>
              <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">live</span>
            </div>
            {recentScans.length === 0 ? (
              <p className="px-5 py-6 text-xs text-slate-400 font-bold uppercase tracking-widest">No scans yet.</p>
            ) : (
              <ul className="divide-y divide-slate-50 max-h-[420px] overflow-y-auto">
                {recentScans.map((scan) => {
                  const ok = scan.status === 'SUCCESS';
                  const undone = scan.status === 'UNDONE';
                  return (
                    <li key={scan.key} className="px-5 py-3">
                      <div className="flex items-center gap-3">
                        <span className={`w-7 h-7 rounded-full flex items-center justify-center shrink-0 ${ok ? 'bg-green-50 text-green-600' : undone ? 'bg-slate-100 text-slate-400' : 'bg-rose-50 text-rose-500'}`}>
                          {ok ? <CheckCircle2 className="w-4 h-4" /> : undone ? <RefreshCw className="w-4 h-4" /> : <XCircle className="w-4 h-4" />}
                        </span>
                        <div className="min-w-0 flex-1">
                          <p className="text-sm font-bold text-slate-800 truncate">{ok ? scan.name : undone ? `${scan.name} · undone` : 'Rejected'}</p>
                          <p className="text-[11px] text-slate-400 truncate uppercase tracking-tighter">…{scan.ticketId.slice(-6)}</p>
                        </div>
                        {ok && canOverride && !isOffline && undoKey !== scan.key ? (
                          <button
                            type="button"
                            onClick={() => { setUndoKey(scan.key); setUndoReason(''); }}
                            className="text-[10px] font-black uppercase tracking-widest text-slate-500 hover:text-slate-900 shrink-0"
                          >
                            Undo
                          </button>
                        ) : null}
                        <span className="text-[10px] font-mono text-slate-300 shrink-0">{scan.time.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
                      </div>
                      {undoKey === scan.key ? (
                        <form
                          className="mt-2 flex gap-2"
                          onSubmit={(e) => { e.preventDefault(); void confirmUndo(scan); }}
                        >
                          <input
                            type="text"
                            value={undoReason}
                            onChange={(e) => setUndoReason(e.target.value)}
                            placeholder="Why undo? e.g. scanned the wrong pass"
                            aria-label="Reason for undoing this check-in"
                            maxLength={300}
                            autoFocus
                            className="min-w-0 flex-1 bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60"
                          />
                          <button
                            type="submit"
                            disabled={undoing || undoReason.trim().length < 3}
                            className="px-3 py-2 bg-slate-900 text-white rounded-lg text-[10px] font-black uppercase tracking-widest disabled:opacity-40"
                          >
                            Undo
                          </button>
                          <button
                            type="button"
                            onClick={() => setUndoKey(null)}
                            aria-label="Keep this check-in"
                            className="px-2 text-slate-400 hover:text-slate-700"
                          >
                            <XCircle className="w-4 h-4" />
                          </button>
                        </form>
                      ) : null}
                    </li>
                  );
                })}
              </ul>
            )}
          </div>

          {/* Refused-scan audit — reads exos_scan_rejects (written by the
              scanner above on every refusal); polled, exportable. */}
          {eventId && <ScanRejectAudit eventId={eventId} eventTitle={event.title} />}
        </div>
      </div>
    </div>
    </div>
  );
}
