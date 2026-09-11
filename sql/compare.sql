-- Cross-marketplace price ladder for one event and one requested quantity.
--
-- Shape (mirrors Terminal-2's n2s_cover_candidates): for each source take the NEWEST
-- capture within the freshness window, join that capture's rows, keep the ones a buyer
-- of %(qty)s tickets could actually take (exact quantity, or a larger lot whose published
-- splits allow it), and return the cheapest %(ladder)s per source plus per-source counts.
-- A source with fresh listings but nothing for this quantity still returns one count-only
-- row (section IS NULL) so the API can say "12 listings, none for 2" instead of "nothing".
--
-- Per-event and bounded: every table is read through its (event, captured_at DESC) index.
-- Never widen to a scan over listings_snapshots (tens of GB).
--
-- Fields deliberately NOT selected (fan-facing whitelist): wholesale_price, brokerage_name,
-- office_*, is_owned, sglid, tevo_ticket_group_id, seller_notes, raw.
WITH ev AS (
  SELECT %(event_id)s::bigint AS eid,
         %(qty)s::int         AS qty,
         (%(max_age_hours)s::int * interval '1 hour') AS max_age
),
p_tevo AS (
  SELECT x.captured_at FROM ev, LATERAL (
    SELECT s.captured_at FROM public.listings_snapshots s
     WHERE s.event_id = ev.eid AND s.captured_at >= now() - ev.max_age
     ORDER BY s.captured_at DESC LIMIT 1) x
),
p_sg AS (
  SELECT x.captured_at FROM ev, LATERAL (
    SELECT s.captured_at FROM public.seatgeek_listings_snapshots s
     WHERE s.tevo_event_id = ev.eid AND s.captured_at >= now() - ev.max_age
     ORDER BY s.captured_at DESC LIMIT 1) x
),
p_gt AS (
  SELECT x.captured_at FROM ev, LATERAL (
    SELECT s.captured_at FROM public.gotickets_listings_snapshots s
     WHERE s.tevo_event_id = ev.eid AND s.captured_at >= now() - ev.max_age
     ORDER BY s.captured_at DESC LIMIT 1) x
),
l AS (
  -- TEvo: our owned rows are the VibePass book (buyable on the storefront); every other
  -- broker's row is the wholesale exchange, a reference price until a buy path exists.
  SELECT CASE WHEN t.is_owned AND t.brokerage_id = %(own_brokerage_id)s::bigint
              THEN 'vibepass' ELSE 'tevo_exchange' END AS src,
         t.section, t."row" AS row, t.quantity,
         t.retail_price::numeric AS unit_price,
         t.splits::int[]        AS splits,
         t.captured_at,
         NULL::text   AS sg_url, NULL::text   AS display_id,
         NULL::bigint AS gt_event_id, NULL::bigint AS gt_section_id,
         COALESCE(t.wheelchair, false) AS accessible,
         false                         AS limited_view
    FROM p_tevo p
    JOIN public.listings_snapshots t
      ON t.event_id = (SELECT eid FROM ev) AND t.captured_at = p.captured_at
   WHERE NOT COALESCE(t.is_ancillary, false)
     AND COALESCE(t.type, '')    NOT ILIKE '%%parking%%'
     AND COALESCE(t.section, '') NOT ILIKE '%%parking%%'
     AND t.retail_price > 0
  UNION ALL
  -- SeatGeek: all-in price; splits are jsonb and must be parsed defensively.
  SELECT 'seatgeek', sg.section, sg."row", sg.quantity,
         sg.retail_price_all_in::numeric,
         CASE WHEN jsonb_typeof(sg.splits) = 'array'
              THEN ARRAY(SELECT e::int FROM jsonb_array_elements_text(sg.splits) AS e
                          WHERE e ~ '^[0-9]+$')
              ELSE NULL::int[] END,
         sg.captured_at,
         c.sg_url, sg.display_id, NULL, NULL,
         COALESCE(sg.is_wheelchair_acc, false),
         COALESCE(sg.has_limited_view, false)
    FROM p_sg p
    JOIN public.seatgeek_listings_snapshots sg
      ON sg.tevo_event_id = (SELECT eid FROM ev) AND sg.captured_at = p.captured_at
    LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = sg.sg_event_id
   WHERE sg.retail_price_all_in > 0
     AND COALESCE(sg.section, '') NOT ILIKE '%%parking%%'
  UNION ALL
  -- GoTickets: all-in price; GA excluded from the seat ladder; WC rows tagged accessible.
  SELECT 'gotickets', g.section, g."row", g.quantity,
         g.all_in_price::numeric, g.splits, g.captured_at,
         NULL, NULL, g.gt_event_id, g.section_id,
         COALESCE(g."row", '') ILIKE 'WC%%',
         false
    FROM p_gt p
    JOIN public.gotickets_listings_snapshots g
      ON g.tevo_event_id = (SELECT eid FROM ev) AND g.captured_at = p.captured_at
   WHERE g.all_in_price > 0
     AND NOT COALESCE(g.general_admission, false)
     AND COALESCE(g.section, '') NOT ILIKE '%%parking%%'
),
c AS (
  SELECT l.*,
         (l.quantity = ev.qty
          OR (l.quantity > ev.qty AND l.splits IS NOT NULL AND ev.qty = ANY(l.splits))) AS qty_ok
    FROM l, ev
),
cnt AS (
  SELECT src,
         count(*)                        AS listings_total,
         count(*) FILTER (WHERE qty_ok)  AS listings_for_qty,
         max(captured_at)                AS captured_at
    FROM c GROUP BY src
),
r AS (
  SELECT c.*, row_number() OVER (PARTITION BY src ORDER BY unit_price, quantity) AS rn
    FROM c WHERE qty_ok
)
SELECT cnt.src, cnt.listings_total, cnt.listings_for_qty, cnt.captured_at,
       r.section, r.row, r.quantity, r.unit_price,
       r.sg_url, r.display_id, r.gt_event_id, r.gt_section_id,
       r.accessible, r.limited_view, r.rn
  FROM cnt
  LEFT JOIN r ON r.src = cnt.src AND r.rn <= %(ladder)s::int
 ORDER BY cnt.src, r.rn NULLS LAST;
