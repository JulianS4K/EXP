import { useEffect, useMemo, type RefObject } from 'react';
import { EMBED_RESIZE, postToHost, resolveHostOrigin } from '../lib/embed';

/** The venue page's origin for this iframe (?host= from embed.js, else the
 *  browser's ancestorOrigins), or null for old snippets / direct visits. */
export function useEmbedHost(): string | null {
  return useMemo(() => {
    if (typeof window === 'undefined') return null;
    const ancestors = (window.location as Location & { ancestorOrigins?: DOMStringList }).ancestorOrigins;
    return resolveHostOrigin(window.location.search, ancestors ?? null);
  }, []);
}

/** Keep telling the host page how tall the embed is so it can size the iframe.
 *  Measures the root element (not the document, which never reports less than
 *  the current iframe height, so the frame could grow but never shrink). */
export function useEmbedResize(host: string | null, root: RefObject<HTMLElement | null>): void {
  useEffect(() => {
    if (typeof window === 'undefined' || window.parent === window) return undefined;
    const postSize = () => {
      const el = root.current;
      const h = el ? Math.ceil(el.getBoundingClientRect().height) : document.documentElement.scrollHeight;
      postToHost({ type: EMBED_RESIZE, height: h }, host, window.parent);
    };
    postSize();
    window.addEventListener('resize', postSize);
    let ro: ResizeObserver | undefined;
    if (typeof ResizeObserver !== 'undefined') {
      ro = new ResizeObserver(postSize);
      ro.observe(root.current ?? document.body);
    }
    return () => {
      window.removeEventListener('resize', postSize);
      ro?.disconnect();
    };
  }, [host, root]);
}
