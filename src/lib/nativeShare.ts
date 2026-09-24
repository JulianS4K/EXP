// Bridge to the future Exos native app (iOS / Android wrapper around this
// SPA). Meta only lets NATIVE apps hand an image to the Instagram / Facebook
// Stories composer (Android intent com.instagram.share.ADD_TO_STORY, iOS
// instagram-stories://share + pasteboard, both needing our Facebook App ID),
// so the web app can't do it. When the app wraps the SPA it injects
// window.ExosNative; the SPA detects it and hands over a ready-made payload
// instead of using the browser share sheet. The native half is specified in
// docs/native-sharing.md. Without the bridge, callers fall back to the web
// path in lib/poster.ts.

export type NativeShareTarget = 'instagram_story' | 'facebook_story' | 'instagram_feed';

export interface NativeSharePayload {
  target: NativeShareTarget;
  /** Full-screen background: data: URL (image/png or image/jpeg), 9:16, at least 720x1280. */
  backgroundImage?: string;
  /** Movable sticker layer: data: URL (image/png or image/jpeg), about 640x480. */
  stickerImage?: string;
  /** Background gradient when there's no background image (#RRGGBB). */
  backgroundTopColor?: string;
  backgroundBottomColor?: string;
  /** The attributed link the user should add as a link sticker. The app puts
   *  it on the clipboard (Meta's API has no link field). */
  contentUrl: string;
}

export type NativeShareResult = 'shared' | 'cancelled' | 'unavailable';

export interface ExosNativeBridge {
  /** Bridge contract version; this SPA speaks version 1. */
  version: number;
  /** Whether the target app is installed and the share can open. */
  canShare(target: NativeShareTarget): Promise<boolean>;
  share(payload: NativeSharePayload): Promise<NativeShareResult>;
}

declare global {
  interface Window {
    ExosNative?: ExosNativeBridge;
  }
}

export const BRIDGE_VERSION = 1;

export function getNativeBridge(w: { ExosNative?: unknown } | undefined = typeof window !== 'undefined' ? window : undefined): ExosNativeBridge | null {
  const b = w?.ExosNative as Partial<ExosNativeBridge> | undefined;
  if (!b || typeof b !== 'object') return null;
  if (b.version !== BRIDGE_VERSION) return null;
  if (typeof b.canShare !== 'function' || typeof b.share !== 'function') return null;
  return b as ExosNativeBridge;
}

const IMAGE_DATA_URL = /^data:image\/(png|jpeg);base64,[A-Za-z0-9+/]/;
const HEX = /^#[0-9A-Fa-f]{6}$/;
// Meta recommends < 50 MB for video; images are far smaller. Keep payloads
// under what a webview message channel handles comfortably.
const MAX_IMAGE_CHARS = 12_000_000;

// Returns a list of problems; empty means the payload is safe to send.
export function validateNativePayload(p: NativeSharePayload): string[] {
  const problems: string[] = [];
  const img = (v: string | undefined, name: string) => {
    if (v === undefined) return;
    if (!IMAGE_DATA_URL.test(v)) problems.push(`${name} must be a PNG or JPEG data URL`);
    else if (v.length > MAX_IMAGE_CHARS) problems.push(`${name} is too large`);
  };
  img(p.backgroundImage, 'backgroundImage');
  img(p.stickerImage, 'stickerImage');
  if (p.target === 'instagram_feed' && !p.backgroundImage) problems.push('instagram_feed needs backgroundImage');
  if (p.target !== 'instagram_feed' && !p.backgroundImage && !p.stickerImage) problems.push('a story needs a background or a sticker');
  for (const [k, v] of [['backgroundTopColor', p.backgroundTopColor], ['backgroundBottomColor', p.backgroundBottomColor]] as const) {
    if (v !== undefined && !HEX.test(v)) problems.push(`${k} must be #RRGGBB`);
  }
  try {
    if (new URL(p.contentUrl).protocol !== 'https:') problems.push('contentUrl must be https');
  } catch {
    problems.push('contentUrl must be a URL');
  }
  return problems;
}

export function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result));
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}
