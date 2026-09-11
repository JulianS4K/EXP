-- Upcoming catalogued events matching a name / performer / venue fragment.
SELECT e.id,
       e.name,
       e.occurs_at_local::text  AS starts_at_local,
       e.venue_name,
       e.venue_location,
       e.primary_performer_name AS performer,
       e.event_type
  FROM public.events e
 WHERE COALESCE(e.state, '') <> 'ignored'
   AND e.occurs_at_local::timestamp >= (now() - interval '6 hours')::timestamp
   AND (e.name ILIKE %(pattern)s
        OR e.primary_performer_name ILIKE %(pattern)s
        OR e.venue_name ILIKE %(pattern)s)
 ORDER BY e.occurs_at_local::timestamp
 LIMIT %(limit)s::int;
