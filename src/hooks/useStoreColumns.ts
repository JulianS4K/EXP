import { useEffect, useState } from 'react';
import { hasStoreColumns } from '../lib/events';

/** True once the store-page columns are known to exist (mig 20260929120000). */
export function useStoreColumns(): boolean {
  const [ok, setOk] = useState(false);
  useEffect(() => {
    let alive = true;
    void hasStoreColumns().then((v) => { if (alive) setOk(v); });
    return () => { alive = false; };
  }, []);
  return ok;
}
