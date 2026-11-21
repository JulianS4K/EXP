// A square (1080x1080) cover from an event image, for pages that want a square
// cover (the Partiful kit). Center crop on a canvas; null when the image can't
// be drawn (CORS, offline, no canvas), so the caller falls back to the link.
// The story size (1080x1920) is lib/poster.ts composeStoryPoster.

export const SQUARE = 1080;

/** The source rectangle of a center crop to a square. */
export function centerSquare(w: number, h: number): { sx: number; sy: number; size: number } {
  const size = Math.min(w, h);
  return { sx: Math.round((w - size) / 2), sy: Math.round((h - size) / 2), size };
}

export async function composeSquareCover(imageUrl: string): Promise<Blob | null> {
  try {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    await new Promise<void>((resolve, reject) => {
      img.onload = () => resolve();
      img.onerror = () => reject(new Error('image'));
      img.src = imageUrl;
    });
    const canvas = document.createElement('canvas');
    canvas.width = SQUARE;
    canvas.height = SQUARE;
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    const { sx, sy, size } = centerSquare(img.naturalWidth, img.naturalHeight);
    ctx.drawImage(img, sx, sy, size, size, 0, 0, SQUARE, SQUARE);
    return await new Promise<Blob | null>((resolve) => canvas.toBlob((b) => resolve(b), 'image/png'));
  } catch {
    return null;
  }
}

/** Save a blob as a file. */
export function downloadBlob(blob: Blob, name: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
