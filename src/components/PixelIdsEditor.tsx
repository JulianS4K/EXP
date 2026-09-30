// Pixel id fields for Settings → Marketing (exos_orgs.marketing.pixels).
//
// Public ids only (they're served to every visitor through exos_public_orgs);
// access tokens for server-side conversions never go here. Each field checks
// the vendor's id format as you type (lib/pixelIds.ts); OrgSettings refuses to
// save while any is malformed. Analytics (GA4) and advertising pixels load
// under separate cookie consent (lib/consent.ts, lib/pixels.ts).

import { Organization } from '../types';
import { isValidPixelId, pixelIdExample, xEventMatchesPixel, type PixelKey } from '../lib/pixelIds';

type Pixels = NonNullable<NonNullable<Organization['marketing']>['pixels']>;

const FIELDS: readonly (readonly [string, PixelKey])[] = [
  ['Meta Pixel', 'meta'],
  ['GA4 (analytics)', 'ga4'],
  ['TikTok Pixel', 'tiktok'],
  ['Reddit Pixel', 'reddit'],
  ['Snap Pixel', 'snap'],
  ['X Pixel', 'x'],
];

const X_EVENTS: readonly (readonly [string, PixelKey])[] = [
  ['X event: view content', 'xViewContent'],
  ['X event: checkout', 'xInitiateCheckout'],
  ['X event: purchase', 'xPurchase'],
];

export default function PixelIdsEditor({
  pixels,
  onChange,
  disabled,
  fieldClass,
}: {
  pixels: Pixels | undefined;
  onChange: (next: Pixels) => void;
  disabled: boolean;
  fieldClass: string;
}) {
  const field = ([label, key]: readonly [string, PixelKey]) => {
    const value = pixels?.[key] ?? '';
    const badFormat = !isValidPixelId(key, value);
    const wrongPixel = !badFormat && key.startsWith('x') && key !== 'x' && !xEventMatchesPixel(pixels?.x?.trim(), value.trim());
    const errId = `pixel-${key}-err`;
    return (
      <label key={key} className="block">
        <span className="text-[10px] text-slate-400 uppercase tracking-widest">{label}</span>
        <input
          type="text"
          className={`${fieldClass} mt-1 ${badFormat || wrongPixel ? 'border-red-400' : ''}`}
          value={value}
          onChange={(e) => onChange({ ...pixels, [key]: e.target.value.trim() })}
          disabled={disabled}
          placeholder={pixelIdExample(key)}
          aria-invalid={badFormat || wrongPixel}
          aria-describedby={badFormat || wrongPixel ? errId : undefined}
          spellCheck={false}
          autoComplete="off"
        />
        {badFormat && <span id={errId} className="block mt-1 text-[10px] text-red-600">Should look like {pixelIdExample(key)}</span>}
        {wrongPixel && <span id={errId} className="block mt-1 text-[10px] text-red-600">Must start with tw-{pixels?.x}-</span>}
      </label>
    );
  };

  return (
    <>
      <div className="grid grid-cols-2 md:grid-cols-3 gap-3">{FIELDS.map(field)}</div>
      {pixels?.x && (
        <>
          <p className="text-[10px] text-slate-400 mt-4 mb-2">
            X sends conversions per event: paste the event ids from X Events Manager (tw-pixel-event). Events without one aren’t sent to X.
          </p>
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3">{X_EVENTS.map(field)}</div>
        </>
      )}
    </>
  );
}

/** True when every pixel id is empty or well-formed (and X events match the X pixel). */
export function pixelIdsSavable(pixels: Pixels | undefined): boolean {
  if (!pixels) return true;
  return [...FIELDS, ...X_EVENTS].every(([, k]) => isValidPixelId(k, pixels[k]))
    && X_EVENTS.every(([, k]) => xEventMatchesPixel(pixels.x?.trim() || undefined, pixels[k]?.trim() || undefined));
}
