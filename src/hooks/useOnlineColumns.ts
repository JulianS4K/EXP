import { useEffect, useState } from 'react';
import { hasOnlineColumns } from '../lib/onlineEventsApi';

/** True once the online-event columns are known to exist (mig 20261005090000). */
export function useOnlineColumns(): boolean {
  const [ok, setOk] = useState(false);
  useEffect(() => {
    let alive = true;
    void hasOnlineColumns().then((v) => { if (alive) setOk(v); });
    return () => { alive = false; };
  }, []);
  return ok;
}
