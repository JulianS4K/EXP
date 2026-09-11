-- One event by canonical TEvo id, plus whether the cross-source hub knows it on
-- SeatGeek / GoTickets. Ids stay server-side; the API exposes booleans.
SELECT e.id,
       e.name,
       e.occurs_at_local::text        AS starts_at_local,
       e.venue_name,
       e.venue_location,
       e.primary_performer_name       AS performer,
       e.event_type,
       (SELECT max(m.sg_event_id) FROM public.aq_event_map m
         WHERE m.tevo_event_id = e.id)                                   AS sg_event_id,
       (SELECT max(c.sg_url) FROM public.sg_events_canonical c
         WHERE c.tevo_event_id = e.id AND COALESCE(c.sg_url, '') <> '')  AS sg_url,
       (SELECT max(g.gt_event_id) FROM public.gotickets_event g
         WHERE g.tevo_event_id = e.id)                                   AS gt_event_id
  FROM public.events e
 WHERE e.id = %(event_id)s::bigint
   AND COALESCE(e.state, '') <> 'ignored';
