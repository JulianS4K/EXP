-- ============================================================================
-- Migration 20261106120000 — Exos: shared capacity (DICE TicketPool)
--
-- Branch:   claude/exos-capacity-pricing (KANBAN "DICE gaps" #3)
-- Touches:  exos_quotas / exos_quota_tiers (W: guards), new SQL cores for the
--           partner API, patches (pg_temp.exos_patch_n, markers below) on
--           exos_assert_quota, exos_create_hold, exos_create_guest_hold,
--           _exos_api_public_tiers_json, _exos_event_publish_blockers.
-- Pre-reqs: 20260702123030 (exos_quotas), 20260928060000 (quota editor),
--           20261105150000 (closed types), 20261104110000 (capacity floor).
--
-- Shared capacity already exists: exos_quotas (a pool: name + size) and
-- exos_quota_tiers (its ticket types), from mig 20260702123030. Holds, the
-- webhook's fulfilment, staff mints and comps, partner reservations,
-- marketplace / channel allocations, vouchers that block inventory and the
-- waitlist all count against it already (exos_effective_available =
-- min(type remaining, every pool's remaining); a type is sellable only when
-- every pool it is in has room). This migration does NOT add a second pool
-- table. DICE's TicketPool {name, allocation} is exos_quotas {name, size}.
-- What it adds:
--
--   1. No unlimited pools. size NULL (the old "unlimited") or negative is
--      refused on insert and on update; 0 closes the pool (stop sales),
--      like a ticket type's capacity (mig 20261105150000). Like a type's
--      capacity (mig 20261104110000 §1), a dashboard write can't set a size
--      below what the pool has already sold (0 still closes it), and a type
--      can't be added to a pool it would push over its size.
--   2. A fixed lock order. exos_assert_quota and both hold functions locked
--      a type's pools in whatever order the index returned them; two buyers
--      of two types sharing two pools could deadlock. They now lock by
--      quota_id, the order exos_seats_available already used.
--   3. The public API's tiers JSON (_exos_api_public_tiers_json) says sold
--      out when a pool is full, and gives the effective available count.
--      (exos_public_tiers.available, read by the storefront, the Google and
--      catalog feeds and MCP, was already pool-aware.)
--   4. Publish blockers: a pool with no ticket types, a pool without a size,
--      and a ticket type that is on sale but sits in a closed pool.
--   5. SQL cores for the partner API's pool routes (docs/api/capacity.json),
--      service role only; exos-api checks the key's org and scope first, and
--      a write needs a key whose creator is an owner or manager (in SQL).
--
-- Additive, replay-safe. D4 authors; not applied.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ===========================================================================
-- 1. No unlimited pools; 0 closes; never below what's sold.
-- ===========================================================================

-- Tickets a pool has sold (the same count exos_quota_available subtracts).
CREATE OR REPLACE FUNCTION public._exos_quota_used(p_quota_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT count(*)::int
    FROM public.exos_tickets t
   WHERE t.tier_id IN (SELECT qt.tier_id FROM public.exos_quota_tiers qt WHERE qt.quota_id = p_quota_id)
     AND t.status IN ('active', 'used', 'transferred');
$$;
REVOKE ALL ON FUNCTION public._exos_quota_used(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_quota_used(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_tg_quota_size_rules()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_used int;
BEGIN
  /* exos: no unlimited pools (mig 20261106120000) */
  IF TG_OP = 'INSERT' OR NEW.size IS DISTINCT FROM OLD.size THEN
    IF NEW.size IS NULL OR NEW.size < 0 THEN
      RAISE EXCEPTION 'shared limit: give it a size of 0 or more (0 closes sales; there is no unlimited)'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  -- Dashboard writes (as anon / authenticated, like the capacity floor of
  -- mig 20261104110000): never below what's already sold; 0 still closes.
  -- (A definer trigger runs as its owner: the caller's role is the role setting.)
  IF TG_OP = 'UPDATE' AND NEW.size IS DISTINCT FROM OLD.size AND NEW.size > 0
     AND coalesce(nullif(current_setting('role', true), 'none'), session_user) IN ('anon', 'authenticated') THEN
    v_used := public._exos_quota_used(NEW.id);
    IF NEW.size < v_used THEN
      RAISE EXCEPTION 'shared limit "%" has already sold %; its size can''t be lower (set it to 0 to stop sales)',
        NEW.name, v_used USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_quota_size_rules() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_quotas_size_rules ON public.exos_quotas;
CREATE TRIGGER exos_quotas_size_rules BEFORE INSERT OR UPDATE ON public.exos_quotas
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_quota_size_rules();

-- Adding a type to a pool it would push over its size (dashboard writes).
CREATE OR REPLACE FUNCTION public.exos_tg_quota_member_floor()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_size int; v_name text; v_used int;
BEGIN
  IF coalesce(nullif(current_setting('role', true), 'none'), session_user) NOT IN ('anon', 'authenticated') THEN
    RETURN NEW;
  END IF;
  SELECT size, name INTO v_size, v_name FROM public.exos_quotas WHERE id = NEW.quota_id;
  IF coalesce(v_size, 0) <= 0 THEN
    RETURN NEW;               -- a closed pool takes any type (it sells nothing)
  END IF;
  SELECT count(*)::int INTO v_used
    FROM public.exos_tickets t
   WHERE (t.tier_id IN (SELECT qt.tier_id FROM public.exos_quota_tiers qt WHERE qt.quota_id = NEW.quota_id)
          OR t.tier_id = NEW.tier_id)
     AND t.status IN ('active', 'used', 'transferred');
  IF v_used > v_size THEN
    RAISE EXCEPTION 'shared limit "%" would count % sold against a size of %: raise the size first', v_name, v_used, v_size
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_quota_member_floor() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_quota_tiers_floor ON public.exos_quota_tiers;
CREATE TRIGGER exos_quota_tiers_floor BEFORE INSERT ON public.exos_quota_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_quota_member_floor();

-- ===========================================================================
-- 2. One lock order for a type's pools: by quota_id (exos_seats_available's).
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public.exos_assert_quota(uuid,integer)',
  '/* exos: pool lock order */',
  $o$FOR r IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id LOOP$o$,
  $n$FOR r IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id ORDER BY quota_id /* exos: pool lock order */ LOOP$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_create_hold(uuid,uuid,integer,integer,text)',
  '/* exos: pool lock order */',
  $o$FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id LOOP$o$,
  $n$FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id ORDER BY quota_id /* exos: pool lock order */ LOOP$n$, 1);
SELECT pg_temp.exos_patch_n('public.exos_create_guest_hold(uuid,uuid,integer,text,text,text)',
  '/* exos: pool lock order */',
  $o$FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id LOOP$o$,
  $n$FOR q IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id ORDER BY quota_id /* exos: pool lock order */ LOOP$n$, 1);

-- ===========================================================================
-- 3. Public API tiers: sold out when a pool is full; the effective count.
-- ===========================================================================
SELECT pg_temp.exos_patch_n('public._exos_api_public_tiers_json(uuid)',
  '/* exos: shared limits sold out */',
  $o$'sold_out', coalesce(t.capacity, 0) <= 0 /* exos: closed is sold out */ OR coalesce(t.sold, 0) >= t.capacity)$o$,
  $n$'sold_out', coalesce(t.capacity, 0) <= 0 /* exos: closed is sold out */ OR coalesce(t.sold, 0) >= t.capacity
             OR coalesce(public.exos_effective_available(t.id), 0) <= 0 /* exos: shared limits sold out */,
           'available', greatest(coalesce(public.exos_effective_available(t.id), 0), 0))$n$, 1);

-- ===========================================================================
-- 4. Publish blockers for pools.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._exos_shared_limit_blockers(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(b ORDER BY b ->> 'code', b ->> 'message'), '[]'::jsonb)
  FROM (
    -- A pool with no ticket types limits nothing: a leftover or a mistake.
    SELECT jsonb_build_object('code', 'shared_limit_no_types', 'field', 'shared_limits',
             'message', format('The shared limit "%s" has no ticket types: add some or delete it.', q.name)) AS b
      FROM public.exos_quotas q
     WHERE q.event_id = p_event_id
       AND NOT EXISTS (SELECT 1 FROM public.exos_quota_tiers qt WHERE qt.quota_id = q.id)
    UNION ALL
    -- A pool from before sizes were required (NULL = the old unlimited).
    SELECT jsonb_build_object('code', 'shared_limit_needs_size', 'field', 'shared_limits',
             'message', format('Give the shared limit "%s" a size (0 closes sales).', q.name))
      FROM public.exos_quotas q
     WHERE q.event_id = p_event_id AND q.size IS NULL
    UNION ALL
    -- A type on sale that can't sell: a pool it is in is closed. A type
    -- sells only when every pool it is in has room, so one closed pool is
    -- enough. Close the type itself (capacity 0) or open the pool.
    SELECT jsonb_build_object('code', 'ticket_type_in_closed_shared_limit', 'field', 'ticket_types',
             'message', format('"%s" is on sale but its shared limit "%s" is closed: open the limit or set "%s" to 0.',
                               t.name, q.name, t.name))
      FROM public.exos_ticket_tiers t
      JOIN public.exos_quota_tiers qt ON qt.tier_id = t.id
      JOIN public.exos_quotas q ON q.id = qt.quota_id
     WHERE t.event_id = p_event_id AND t.capacity > 0
       AND (t.sales_end IS NULL OR t.sales_end > now())
       AND (q.closed OR q.size = 0)
  ) x
  WHERE EXISTS (SELECT 1 FROM public.exos_events e
                 WHERE e.id = p_event_id AND coalesce(to_jsonb(e) ->> 'ticket_backend', 'exos') = 'exos');
$$;
REVOKE ALL ON FUNCTION public._exos_shared_limit_blockers(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_shared_limit_blockers(uuid) TO service_role;

SELECT pg_temp.exos_patch_n('public._exos_event_publish_blockers(uuid)',
  '/* exos: shared limit blockers */',
  $o$v_out := v_out || public._exos_location_blockers(p_event_id);   /* exos: location blockers */$o$,
  $n$v_out := v_out || public._exos_location_blockers(p_event_id);   /* exos: location blockers */
  v_out := v_out || public._exos_shared_limit_blockers(p_event_id);   /* exos: shared limit blockers */$n$, 1);

-- ===========================================================================
-- 5. Partner API cores (service role; exos-api/capacity.ts names the org).
-- ===========================================================================

-- One pool with its counts. remaining = exos_quota_available (holds, vouchers
-- that block inventory and channel allocations already taken off).
CREATE OR REPLACE FUNCTION public._exos_api_capacity_pool_json(p_quota_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
           'id', q.id, 'event_id', q.event_id, 'name', q.name,
           'allocation', q.size, 'closed', q.closed OR q.size = 0,
           'ticket_type_ids', coalesce((SELECT jsonb_agg(qt.tier_id ORDER BY qt.tier_id)
                                          FROM public.exos_quota_tiers qt WHERE qt.quota_id = q.id), '[]'::jsonb),
           'sold', public._exos_quota_used(q.id),
           'held', (SELECT coalesce(sum(h.quantity * public.exos_tier_party_size(h.tier_id)), 0)::int
                      FROM public.exos_cart_holds h
                     WHERE h.tier_id IN (SELECT qt.tier_id FROM public.exos_quota_tiers qt WHERE qt.quota_id = q.id)
                       AND h.status = 'active' AND h.expires_at > now()),
           'remaining', coalesce(public.exos_quota_available(q.id), 0),
           'sold_out', coalesce(public.exos_quota_available(q.id), 0) <= 0,
           'created_at', q.created_at, 'updated_at', q.updated_at)
    FROM public.exos_quotas q WHERE q.id = p_quota_id;
$$;
REVOKE ALL ON FUNCTION public._exos_api_capacity_pool_json(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_api_capacity_pool_json(uuid) TO service_role;

-- Reads follow events:read for ticket types (any key of the org with that
-- scope, its creator's role narrowing the scopes): no role rule here either.
CREATE OR REPLACE FUNCTION public._exos_api_capacity_pools(p_org uuid, p_event uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(public._exos_api_capacity_pool_json(q.id) ORDER BY q.created_at, q.id)
                     FROM public.exos_quotas q WHERE q.event_id = p_event AND q.org_id = p_org), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public._exos_api_capacity_pools(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_api_capacity_pools(uuid, uuid) TO service_role;

-- Create (p_pool NULL), update or delete (p_delete) a pool. Body keys: name,
-- allocation (whole number >= 0, required on create), closed, ticket_type_ids
-- (the full list; replaces the old one). The same rules as the dashboard:
-- never below what's sold (0 closes), only this event's types.
-- Who: the API key acts as its creator (mig 20261104180000), and only an
-- owner or manager changes inventory, as for a ticket type in exos_api_write
-- (the exos_quotas_wr policy). Enforced here, not only in exos-api.
CREATE OR REPLACE FUNCTION public._exos_api_capacity_pool_write(p_org uuid, p_api_key uuid, p_event uuid, p_pool uuid, p jsonb, p_delete boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id    uuid := p_pool;
  v_row   public.exos_quotas%ROWTYPE;
  v_alloc int;
  v_types uuid[];
  v_key   text;
  v_used  int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event AND org_id = p_org) THEN
    RAISE EXCEPTION 'event not found' USING ERRCODE = 'P0002';
  END IF;
  -- 42501 unless the key's creator is an active owner or manager of the org.
  PERFORM public._exos_api_key_actor(p_org, p_api_key, ARRAY['owner', 'manager']);
  IF v_id IS NOT NULL THEN
    SELECT * INTO v_row FROM public.exos_quotas WHERE id = v_id AND event_id = p_event AND org_id = p_org FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'shared limit not found' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  IF p_delete THEN
    DELETE FROM public.exos_quotas WHERE id = v_id;
    RETURN jsonb_build_object('id', v_id, 'deleted', true);
  END IF;

  p := coalesce(p, '{}'::jsonb);
  IF jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'send a JSON object' USING ERRCODE = '22023';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p) LOOP
    IF v_key NOT IN ('name', 'allocation', 'closed', 'ticket_type_ids') THEN
      RAISE EXCEPTION 'unknown field %', left(v_key, 60) USING ERRCODE = '22023';
    END IF;
  END LOOP;
  IF p ? 'allocation' THEN
    IF jsonb_typeof(p -> 'allocation') <> 'number' OR (p ->> 'allocation') !~ '^[0-9]{1,9}$' THEN
      RAISE EXCEPTION 'allocation must be a whole number, 0 or more (0 closes sales; there is no unlimited)' USING ERRCODE = '22023';
    END IF;
    v_alloc := (p ->> 'allocation')::int;
  ELSIF v_id IS NULL THEN
    RAISE EXCEPTION 'allocation is required (0 closes sales; there is no unlimited)' USING ERRCODE = '22023';
  END IF;
  IF p ? 'closed' AND jsonb_typeof(p -> 'closed') <> 'boolean' THEN
    RAISE EXCEPTION 'closed must be true or false' USING ERRCODE = '22023';
  END IF;
  IF p ? 'name' AND (jsonb_typeof(p -> 'name') <> 'string' OR btrim(p ->> 'name') = '') THEN
    RAISE EXCEPTION 'name must be a non-empty string' USING ERRCODE = '22023';
  END IF;
  IF v_id IS NULL AND NOT p ? 'name' THEN
    RAISE EXCEPTION 'name is required' USING ERRCODE = '22023';
  END IF;
  IF p ? 'ticket_type_ids' THEN
    IF jsonb_typeof(p -> 'ticket_type_ids') <> 'array'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p -> 'ticket_type_ids') x
                   WHERE jsonb_typeof(x) <> 'string'
                      OR (x #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
      RAISE EXCEPTION 'ticket_type_ids must be an array of ticket type ids' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(array_agg(DISTINCT (x #>> '{}')::uuid), '{}') INTO v_types FROM jsonb_array_elements(p -> 'ticket_type_ids') x;
    IF EXISTS (SELECT 1 FROM unnest(v_types) u(id)
                WHERE NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers t WHERE t.id = u.id AND t.event_id = p_event)) THEN
      RAISE EXCEPTION 'a ticket type in ticket_type_ids is not on this event' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.exos_quotas (event_id, org_id, name, size, closed)
    VALUES (p_event, p_org, p ->> 'name', v_alloc, coalesce((p ->> 'closed')::boolean, false))
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.exos_quotas
       SET name   = CASE WHEN p ? 'name' THEN p ->> 'name' ELSE name END,
           size   = CASE WHEN p ? 'allocation' THEN v_alloc ELSE size END,
           closed = CASE WHEN p ? 'closed' THEN (p ->> 'closed')::boolean ELSE closed END
     WHERE id = v_id;
  END IF;
  IF v_types IS NOT NULL THEN
    DELETE FROM public.exos_quota_tiers WHERE quota_id = v_id AND NOT (tier_id = ANY (v_types));
    INSERT INTO public.exos_quota_tiers (quota_id, tier_id)
    SELECT v_id, u.id FROM unnest(v_types) u(id) ON CONFLICT DO NOTHING;
  END IF;
  -- Never below what the pool has sold (0 closes it), with the new types.
  SELECT size INTO v_alloc FROM public.exos_quotas WHERE id = v_id;
  v_used := public._exos_quota_used(v_id);
  IF v_alloc > 0 AND v_alloc < v_used THEN
    RAISE EXCEPTION 'this shared limit has already sold %; its allocation can''t be lower (0 stops sales)', v_used
      USING ERRCODE = '23514';
  END IF;
  RETURN public._exos_api_capacity_pool_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_api_capacity_pool_write(uuid, uuid, uuid, uuid, jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_api_capacity_pool_write(uuid, uuid, uuid, uuid, jsonb, boolean) TO service_role;

COMMENT ON TABLE public.exos_quotas IS
  'Shared capacity pools (DICE TicketPool; "Shared limits" in the editor). size = allocation, required, 0 closes '
  'sales (mig 20261106120000; NULL was the old unlimited). A type sells only when every pool it is in has room.';
