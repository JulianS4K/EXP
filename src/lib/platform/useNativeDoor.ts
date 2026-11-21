// The door page's native extras, in one hook so OrganizerCheckIn only calls
// it: keep the screen on while the door is open, and pass each scan result
// to the native scanner overlay (colour + haptic). Does nothing on the web.

import { useEffect } from 'react';
import { platform, type DoorScanStatus } from './adapters';

export function useNativeDoor(status: DoorScanStatus): void {
  useEffect(() => {
    const door = platform().door;
    if (!door) return undefined;
    void door.keepAwake(true).catch(() => {});
    return () => {
      void door.keepAwake(false).catch(() => {});
    };
  }, []);

  useEffect(() => {
    platform().scanner?.showStatus?.(status);
  }, [status]);
}
