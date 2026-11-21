// The door camera in the app: ML Kit (@capacitor-mlkit/barcode-scanning)
// behind the SPA's ScannerAdapter (src/lib/platform/adapters.ts).
//
// startScan() draws the camera BEHIND the web view, so while it runs the page
// is hidden (body.barcode-scanner-active) and this module shows its own small
// overlay on top: a frame, the last result (green / red, from the door's
// status), a torch toggle and "Done". Haptics mark each read and each answer.
// If the camera can't open (no permission, no camera), start() rejects and
// the door falls back to its in-page html5-qrcode scanner.

import { BarcodeFormat, BarcodeScanner, LensFacing } from '@capacitor-mlkit/barcode-scanning';
import { Haptics, ImpactStyle, NotificationType } from '@capacitor/haptics';
import type { PluginListenerHandle } from '@capacitor/core';
import type { DoorScanStatus, NativeScanSession, ScannerAdapter } from '../../../src/lib/platform/adapters';
import { scanDeduper, scanFeedback } from '../../../src/lib/platform/scanDedupe';

// Exos codes are QR; imported guest lists (Eventbrite, DICE, ...) and printed
// tickets can carry the other common ticket symbologies.
const FORMATS = [BarcodeFormat.QrCode, BarcodeFormat.Aztec, BarcodeFormat.Pdf417, BarcodeFormat.DataMatrix, BarcodeFormat.Code128];

const STYLE_ID = 'exos-native-scan-style';
const OVERLAY_ID = 'exos-native-scan';

const CSS = `
body.barcode-scanner-active { visibility: hidden; background: transparent !important; }
html.exos-native-scanning, html.exos-native-scanning body { background: transparent !important; }
#${OVERLAY_ID} { visibility: visible; position: fixed; inset: 0; z-index: 2147483647; display: flex; flex-direction: column;
  justify-content: space-between; padding: max(16px, env(safe-area-inset-top)) 16px max(16px, env(safe-area-inset-bottom));
  font: 600 16px/1.3 system-ui, -apple-system, sans-serif; color: #fff; pointer-events: none; }
#${OVERLAY_ID} .frame { align-self: center; width: min(70vw, 70vh); aspect-ratio: 1; border: 4px solid #FFE714; border-radius: 16px; margin: auto 0; }
#${OVERLAY_ID} .status { min-height: 56px; border-radius: 12px; padding: 16px; text-align: center; background: rgba(0,0,0,.72); }
#${OVERLAY_ID} .status[data-tone="success"] { background: #15803d; }
#${OVERLAY_ID} .status[data-tone="error"] { background: #b91c1c; }
#${OVERLAY_ID} .status[data-tone="attention"] { background: #b45309; }
#${OVERLAY_ID} .bar { display: flex; gap: 12px; pointer-events: auto; }
#${OVERLAY_ID} button { flex: 1; min-height: 56px; border-radius: 12px; border: 2px solid #fff; background: rgba(0,0,0,.72);
  color: #fff; font: inherit; }
#${OVERLAY_ID} button:focus-visible { outline: 3px solid #FFE714; outline-offset: 2px; }
`;

const STATUS_TEXT: Partial<Record<DoorScanStatus, string>> = {
  searching: 'Checking…',
  success: 'Admitted',
  'already-used': 'Already used',
  'not-found': 'Ticket not found',
  'invalid-barcode': 'Not a valid code',
  'needs-reason': 'Needs a manager: tap Done for details',
  'by-name': 'Check in by name: tap Done',
};

function ensureStyle(): void {
  if (document.getElementById(STYLE_ID)) return;
  const style = document.createElement('style');
  style.id = STYLE_ID;
  style.textContent = CSS;
  document.head.appendChild(style);
}

function buildOverlay(onTorch: () => void, onDone: () => void): { root: HTMLElement; status: HTMLElement } {
  const root = document.createElement('div');
  root.id = OVERLAY_ID;
  root.setAttribute('role', 'dialog');
  root.setAttribute('aria-label', 'Ticket scanner');
  const status = document.createElement('div');
  status.className = 'status';
  status.setAttribute('role', 'status');
  status.setAttribute('aria-live', 'polite');
  status.textContent = 'Point the camera at a ticket';
  const frame = document.createElement('div');
  frame.className = 'frame';
  frame.setAttribute('aria-hidden', 'true');
  const bar = document.createElement('div');
  bar.className = 'bar';
  const torch = document.createElement('button');
  torch.type = 'button';
  torch.textContent = 'Torch';
  torch.setAttribute('aria-pressed', 'false');
  torch.addEventListener('click', () => {
    torch.setAttribute('aria-pressed', torch.getAttribute('aria-pressed') === 'true' ? 'false' : 'true');
    onTorch();
  });
  const done = document.createElement('button');
  done.type = 'button';
  done.textContent = 'Done';
  done.addEventListener('click', onDone);
  bar.append(torch, done);
  root.append(status, frame, bar);
  return { root, status };
}

let active: { status: HTMLElement } | null = null;

async function feedback(kind: 'read' | 'success' | 'error' | 'attention'): Promise<void> {
  try {
    if (kind === 'read') await Haptics.impact({ style: ImpactStyle.Light });
    else if (kind === 'success') await Haptics.notification({ type: NotificationType.Success });
    else if (kind === 'error') await Haptics.notification({ type: NotificationType.Error });
    else await Haptics.notification({ type: NotificationType.Warning });
  } catch {
    /* no haptics engine */
  }
}

export function mlkitScanner(): ScannerAdapter {
  return {
    async start({ onCode, onClose }): Promise<NativeScanSession> {
      const { supported } = await BarcodeScanner.isSupported();
      if (!supported) throw new Error('No camera scanner on this device');
      let perm = await BarcodeScanner.checkPermissions();
      if (perm.camera !== 'granted' && perm.camera !== 'limited') perm = await BarcodeScanner.requestPermissions();
      if (perm.camera !== 'granted' && perm.camera !== 'limited') throw new Error('Camera permission denied');

      ensureStyle();
      const fresh = scanDeduper();
      let stopped = false;
      let listener: PluginListenerHandle | null = null;
      const stop = async () => {
        if (stopped) return;
        stopped = true;
        active = null;
        document.getElementById(OVERLAY_ID)?.remove();
        document.body.classList.remove('barcode-scanner-active');
        document.documentElement.classList.remove('exos-native-scanning');
        await listener?.remove().catch(() => {});
        await BarcodeScanner.stopScan().catch(() => {});
      };
      const overlay = buildOverlay(
        () => void BarcodeScanner.toggleTorch().catch(() => {}),
        () => {
          void stop();
          onClose?.();
        },
      );

      listener = await BarcodeScanner.addListener('barcodesScanned', (event) => {
        for (const b of event.barcodes) {
          const text = b.rawValue ?? b.displayValue;
          if (text && fresh(text)) {
            void feedback('read');
            onCode(text);
          }
        }
      });
      document.documentElement.classList.add('exos-native-scanning');
      document.body.classList.add('barcode-scanner-active');
      document.body.appendChild(overlay.root);
      active = { status: overlay.status };
      try {
        await BarcodeScanner.startScan({ formats: FORMATS, lensFacing: LensFacing.Back });
      } catch (err) {
        await stop();
        throw err;
      }
      return { stop };
    },
    showStatus(status) {
      if (!active) return;
      const tone = scanFeedback(status);
      active.status.dataset.tone = tone ?? '';
      const text = STATUS_TEXT[status];
      if (text) active.status.textContent = text;
      if (tone) void feedback(tone);
    },
  };
}
