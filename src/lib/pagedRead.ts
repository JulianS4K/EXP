// Read every page of a range-paged PostgREST read. Its own module (it was in
// lib/door/roster.ts) so pages that only page through a list, like the event
// page via lib/tickets.ts, don't download the door's offline roster code.

const DEFAULT_PAGE_SIZE = 1000;
/** Safety stop: 1000 pages of 1000 = a million rows. */
const MAX_PAGES = 1000;

/** Fetch every page of a range-paged read. Pages are requested until one
 *  comes back empty, so a server row cap smaller than `pageSize` (PostgREST
 *  max_rows) can't silently truncate the list. A page larger than asked means
 *  the server ignored the range and returned everything: that's the whole list.
 *  Rows are de-duplicated by `keyOf` (a sale between two pages can shift one). */
export async function fetchAllPages<T>(
  fetchPage: (from: number, to: number) => Promise<T[]>,
  keyOf: (row: T) => string,
  pageSize: number = DEFAULT_PAGE_SIZE,
): Promise<T[]> {
  const seen = new Map<string, T>();
  let from = 0;
  for (let i = 0; i < MAX_PAGES; i++) {
    const page = await fetchPage(from, from + pageSize - 1);
    if (!page || page.length === 0) break;
    for (const row of page) seen.set(keyOf(row), row);
    if (page.length > pageSize) break;
    from += page.length;
  }
  return [...seen.values()];
}
