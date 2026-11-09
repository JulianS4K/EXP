// Reduced motion for motion/react (WCAG 2.3.3, and what the OS setting asks for).
//
// App.tsx wraps everything in <MotionConfig reducedMotion="user">: for a user
// whose OS asks for reduced motion, motion turns transform and layout
// animations off. It keeps opacity animations, though, so a fade-in from
// `initial={{ opacity: 0 }}` still starts the content invisible and fades it
// up. `enter` / `leave` close that gap: with reduced motion on, an element has
// no entrance (`initial={false}` renders it at its `animate` values, full
// opacity, on the first frame) and no exit (AnimatePresence removes it at
// once). Everyone else keeps the animation exactly as written.
import { useReducedMotion } from 'motion/react';

export type MotionGate = {
  reduce: boolean;
  /** `initial` for a motion element: the given values, or false (no entrance). */
  enter<T>(initial: T): T | false;
  /** `exit` for a motion element: the given values, or none (removed at once). */
  leave<T>(exit: T): T | undefined;
};

export function motionGate(reduce: boolean | null | undefined): MotionGate {
  const on = reduce === true;
  return {
    reduce: on,
    enter: (initial) => (on ? false : initial),
    leave: (exit) => (on ? undefined : exit),
  };
}

/** motionGate for the user's current reduced-motion setting (updates live). */
export function useMotionGate(): MotionGate {
  return motionGate(useReducedMotion());
}
