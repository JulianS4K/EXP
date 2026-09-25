// The accounts a share should @-tag: the event's organizer and, when the
// sharer arrived through (or is) a promoter, that promoter. Only accounts that
// allow tagging come back with handles (lib/socialTags.ts).

import { useEffect, useState } from 'react';
import { getPublicOrg } from '../lib/orgs';
import { getPublicPromoter } from '../lib/promoters';
import { orgTagSource, type TagSource } from '../lib/socialTags';
import type { Organization } from '../types';

interface Options {
  orgId?: string | null;
  /** Pass the org when the page already has it, to skip a fetch. */
  org?: Organization | null;
  promoterCode?: string | null;
  /** Leave the org out (a promoter or organizer doesn't tag themselves the same way). */
  includeOrg?: boolean;
  includePromoter?: boolean;
  enabled?: boolean;
}

export function useShareTags({ orgId, org, promoterCode, includeOrg = true, includePromoter = true, enabled = true }: Options): TagSource[] {
  const [tags, setTags] = useState<TagSource[]>([]);

  useEffect(() => {
    if (!enabled) return undefined;
    let alive = true;
    (async () => {
      const theOrg = org ?? (orgId ? await getPublicOrg(orgId).catch(() => null) : null);
      const out: TagSource[] = [];
      if (includeOrg) {
        const o = orgTagSource(theOrg);
        if (o) out.push(o);
      }
      if (includePromoter && promoterCode && theOrg?.slug) {
        const card = await getPublicPromoter(theOrg.slug, promoterCode).catch(() => null);
        if (card?.promoter.socials) out.push({ handles: card.promoter.socials });
      }
      if (alive) setTags(out);
    })();
    return () => {
      alive = false;
    };
  }, [enabled, orgId, org, promoterCode, includeOrg, includePromoter]);

  return tags;
}
