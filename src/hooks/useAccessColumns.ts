import { useEffect, useState } from 'react';
import { hasAccessColumns } from '../lib/accessibilityApi';

/** True once the accessibility columns are known to exist (mig 20260926090000). */
export function useAccessColumns(): boolean {
  const [ok, setOk] = useState(false);
  useEffect(() => {
    let alive = true;
    void hasAccessColumns().then((v) => { if (alive) setOk(v); });
    return () => { alive = false; };
  }, []);
  return ok;
}
