// Dialog: the one modal overlay every popup in the app uses (sign-in, share,
// guest checkout, receipts, confirmations).
//
// What it guarantees:
//   - role="dialog" + aria-modal, labelled by the caller's heading id.
//   - Escape closes; clicking the backdrop closes (both skipped while
//     `dismissible` is false, e.g. while a request is in flight).
//   - Focus moves into the dialog on open (an [autofocus] element, else the
//     first focusable, else the panel), Tab / Shift+Tab stay inside it, and
//     focus goes back to whatever opened it on close.
//   - The page behind doesn't scroll while it's open.
//
// The entrance animation is plain CSS (.anim-fade-in / .anim-pop-in in
// index.css) so the sign-in modal doesn't pull the motion library into the
// entry bundle.

import { ReactNode, useEffect, useRef } from 'react';

const FOCUSABLE = [
  'a[href]',
  'area[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'iframe',
  '[tabindex]:not([tabindex="-1"])',
  '[contenteditable="true"]',
].join(',');

function focusableIn(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
    (el) => !el.hasAttribute('inert') && el.getAttribute('aria-hidden') !== 'true',
  );
}

export interface DialogProps {
  open: boolean;
  onClose: () => void;
  /** id of the element that names the dialog (usually its <h2>). */
  labelledBy: string;
  /** Optional id of a description element. */
  describedBy?: string;
  children: ReactNode;
  /** Classes for the panel (size, background, border, padding). */
  className?: string;
  /** Where the panel sits: centered by default, bottom sheet on mobile with 'sheet'. */
  placement?: 'center' | 'sheet';
  /** Backdrop color classes. */
  backdropClassName?: string;
  /** False blocks Escape / backdrop close (e.g. while submitting). */
  dismissible?: boolean;
}

export default function Dialog({
  open,
  onClose,
  labelledBy,
  describedBy,
  children,
  className = 'w-full max-w-md bg-black border border-white/10 p-6',
  placement = 'center',
  backdropClassName = 'bg-black/70',
  dismissible = true,
}: DialogProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const onCloseRef = useRef(onClose);
  const dismissibleRef = useRef(dismissible);
  onCloseRef.current = onClose;
  dismissibleRef.current = dismissible;

  // Remember what had focus when the dialog opened. Captured during render,
  // not in the effect: a child with autoFocus is focused during commit, before
  // any effect runs, which would hide the real opener.
  const openerRef = useRef<HTMLElement | null>(null);
  const wasOpenRef = useRef(false);
  if (open && !wasOpenRef.current && typeof document !== 'undefined') {
    openerRef.current = document.activeElement as HTMLElement | null;
  }
  wasOpenRef.current = open;

  useEffect(() => {
    if (!open) return undefined;
    const opener = openerRef.current;
    const panel = panelRef.current;

    // Move focus in. Children with autoFocus have already grabbed focus
    // during commit; only step in when focus is still outside the panel.
    if (panel && !panel.contains(document.activeElement)) {
      const auto = panel.querySelector<HTMLElement>('[autofocus],[data-autofocus]');
      (auto ?? focusableIn(panel)[0] ?? panel).focus();
    }

    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (dismissibleRef.current) {
          e.stopPropagation();
          onCloseRef.current();
        }
        return;
      }
      if (e.key !== 'Tab' || !panelRef.current) return;
      const items = focusableIn(panelRef.current);
      if (items.length === 0) {
        e.preventDefault();
        panelRef.current.focus();
        return;
      }
      const first = items[0];
      const last = items[items.length - 1];
      const active = document.activeElement;
      if (e.shiftKey && (active === first || !panelRef.current.contains(active))) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && (active === last || !panelRef.current.contains(active))) {
        e.preventDefault();
        first.focus();
      }
    };
    document.addEventListener('keydown', onKeyDown);

    return () => {
      document.removeEventListener('keydown', onKeyDown);
      document.body.style.overflow = prevOverflow;
      if (opener && opener.isConnected && typeof opener.focus === 'function') opener.focus();
    };
  }, [open]);

  if (!open) return null;

  const align = placement === 'sheet' ? 'items-end md:items-center' : 'items-center';
  return (
    <div
      className={`fixed inset-0 z-50 flex ${align} justify-center p-4`}
      // mousedown (not click) so a drag that starts inside the panel and
      // ends on the backdrop doesn't close it.
      onMouseDown={(e) => {
        if (e.target === e.currentTarget && dismissible) onClose();
      }}
    >
      <div aria-hidden="true" className={`absolute inset-0 pointer-events-none anim-fade-in ${backdropClassName}`} />
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy}
        aria-describedby={describedBy}
        tabIndex={-1}
        className={`relative anim-pop-in focus:outline-none ${className}`}
      >
        {children}
      </div>
    </div>
  );
}
