-- ============================================================================
-- Membership products, staff-issued memberships, imported attendees: writes
-- for the dashboard and the partner API; season-pass wallet cards
-- (Opendate parity: membership_products, admin_memberships,
-- admin_migrated_attendees, fan_app season-pass wallet). docs/memberships.md.
-- ============================================================================
-- Touches:  A: exos_membership_products.status (draft / published /
--              unpublished / archived; kept in step with active / archived_at)
--           A: exos_fan_memberships.member_name / staff_notes / issued_by;
--              source gains 'import' (staff-issued, paid somewhere else)
--           N: _exos_tg_membership_product_status (trigger)
--           N: exos_membership_product_save, exos_membership_product_transition,
--              exos_org_membership_products,
--              exos_membership_issue, exos_membership_update,
--              exos_org_memberships_page, exos_claim_my_memberships,
--              exos_org_imported_attendees, exos_imported_attendee_update,
--              exos_imported_attendee_delete, exos_wallet_season_pass,
--              exos_api_commerce_write (+ internal helpers)
--           R: exos_membership_products, exos_fan_memberships, exos_api_keys,
--              exos_api_writes, exos_org_memberships, exos_guest_list_entries,
--              exos_guest_lists, exos_events, exos_passes, exos_orgs
--           Calls (unchanged): exos_update_guest, exos_remove_guest,
--              _exos_api_insert / _exos_api_update / _exos_api_has_scope,
--              _exos_membership_benefits_live, exos_membership_effective_status,
--              exos_rate_hit, exos_enqueue_webhook
-- Pre-reqs: 20261030130500 (memberships), 20261031110000 (core API: write
--           log, field helpers), 20261013090000 (door imports),
--           20261013100000 (Eventbrite-synced guests: external_ref).
--
-- Product lifecycle: draft -> published <-> unpublished -> archived.
-- Archived is terminal (nothing brings it back). A product that has been sold
-- can't be deleted (the 20261030130500 guard): archive it. Existing members
-- keep their benefits until their period ends: a membership carries the
-- benefits it was bought with (benefits jsonb), and a subscription keeps the
-- price it was created with in Stripe, so editing a product (price included)
-- changes nothing for current members. `active` / `archived_at` stay the
-- columns checkout and the public view read: the trigger keeps them equal to
-- the status (published <=> active), and an old client that flips `active`
-- still moves the status.
--
-- Staff-issued memberships (comp, or 'import': paid somewhere else) start
-- active, with the product's benefits, a one-time term and no Stripe
-- subscription. Staff may later rename the member, change the notes, move the
-- end date or cancel / expire / reactivate one, except that a refunded or
-- cancelled-gift membership (ended_reason) is never revived, a pending gift is
-- changed with the gift functions, and a Stripe-billed one's status and period
-- mirror Stripe (cancel it through Stripe).
--
-- Imported attendees are the door-import guests (exos_import_guests) and
-- their kin: guest entries with a source, an external code or an external
-- ref. Edits go through exos_update_guest (list caps, plus-ones, capacity);
-- the code, ticket label and source are set here. An Eventbrite-synced row
-- (external_ref) is the sync's: edit it on Eventbrite. A checked-in row can't
-- be deleted, nor its code changed.
--
-- The API (exos-api, ./memberships.ts) writes through exos_api_commerce_write,
-- the same steps as exos_api_write (20261031110000): the key, its scope, run
-- as the key's creator while an active member, the Idempotency-Key log in
-- exos_api_writes, then the dashboard RPC above. Its own function, so the
-- core API's one big CASE stays untouched.
--
-- Additive; re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_membership_products ADD COLUMN IF NOT EXISTS status text;
UPDATE public.exos_membership_products
   SET status = CASE WHEN archived_at IS NOT NULL THEN 'archived' WHEN active THEN 'published' ELSE 'unpublished' END
 WHERE status IS NULL;
ALTER TABLE public.exos_membership_products ALTER COLUMN status SET NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_membership_products_status_chk') THEN
    ALTER TABLE public.exos_membership_products ADD CONSTRAINT exos_membership_products_status_chk
      CHECK (status IN ('draft', 'published', 'unpublished', 'archived'));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS exos_membership_products_status_idx ON public.exos_membership_products (org_id, status);

ALTER TABLE public.exos_fan_memberships
  ADD COLUMN IF NOT EXISTS member_name text,
  ADD COLUMN IF NOT EXISTS staff_notes text,
  ADD COLUMN IF NOT EXISTS issued_by   uuid;
DO $$
DECLARE c text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_fan_memberships_member_name_chk') THEN
    ALTER TABLE public.exos_fan_memberships ADD CONSTRAINT exos_fan_memberships_member_name_chk
      CHECK (member_name IS NULL OR length(member_name) BETWEEN 1 AND 120);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_fan_memberships_staff_notes_chk') THEN
    ALTER TABLE public.exos_fan_memberships ADD CONSTRAINT exos_fan_memberships_staff_notes_chk
      CHECK (staff_notes IS NULL OR length(staff_notes) <= 2000);
  END IF;
  -- source: + 'import'. The original check is inline (auto-named); drop it once.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_fan_memberships_source_chk') THEN
    FOR c IN SELECT conname FROM pg_constraint
              WHERE conrelid = 'public.exos_fan_memberships'::regclass AND contype = 'c'
                AND pg_get_constraintdef(oid) LIKE '%source%' AND pg_get_constraintdef(oid) LIKE '%comp%' LOOP
      EXECUTE format('ALTER TABLE public.exos_fan_memberships DROP CONSTRAINT %I', c);
    END LOOP;
    ALTER TABLE public.exos_fan_memberships ADD CONSTRAINT exos_fan_memberships_source_chk
      CHECK (source IN ('purchase', 'gift', 'comp', 'import'));
  END IF;
END $$;
-- The holder may read the member name; staff notes and issued_by are staff's
-- (read through exos_org_memberships_page). Column grants, as for
-- gift_token_hash in 20261030130500. That migration's block grants every
-- column it finds, so a replay of it after this one would hand these out:
-- take them back each run.
GRANT SELECT (member_name) ON public.exos_fan_memberships TO authenticated;
REVOKE SELECT (staff_notes, issued_by) ON public.exos_fan_memberships FROM authenticated;

-- ---------------------------------------------------------------------------
-- 2. Product status, kept in step with active / archived_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_tg_membership_product_status()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.status := coalesce(NEW.status,
      CASE WHEN NEW.archived_at IS NOT NULL THEN 'archived' WHEN NEW.active THEN 'published' ELSE 'unpublished' END);
  ELSE
    IF OLD.status = 'archived' AND (NEW.status IS DISTINCT FROM 'archived' OR NEW.active OR NEW.archived_at IS NULL) THEN
      RAISE EXCEPTION 'an archived membership product can''t be brought back' USING ERRCODE = '55000';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF NOT ((OLD.status, NEW.status) IN (('draft', 'published'), ('draft', 'archived'), ('published', 'unpublished'),
                                           ('published', 'archived'), ('unpublished', 'published'), ('unpublished', 'archived'))) THEN
        RAISE EXCEPTION 'a membership product can''t go from % to %', OLD.status, coalesce(NEW.status, 'nothing')
          USING ERRCODE = '55000';
      END IF;
    ELSIF NEW.active IS DISTINCT FROM OLD.active OR NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      -- An older client flipped active / archived_at: move the status with it.
      NEW.status := CASE WHEN NEW.archived_at IS NOT NULL THEN 'archived' WHEN NEW.active THEN 'published'
                         WHEN OLD.status = 'draft' THEN 'draft' ELSE 'unpublished' END;
    END IF;
  END IF;
  NEW.active := NEW.status = 'published';
  NEW.archived_at := CASE WHEN NEW.status = 'archived' THEN coalesce(NEW.archived_at, now()) END;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_membership_product_status() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_membership_products_status ON public.exos_membership_products;
CREATE TRIGGER exos_membership_products_status BEFORE INSERT OR UPDATE ON public.exos_membership_products
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_membership_product_status();

-- ---------------------------------------------------------------------------
-- 3. Products: save and lifecycle (owner / manager)
-- ---------------------------------------------------------------------------
-- A product as the API and the dashboard table show it.
CREATE OR REPLACE FUNCTION public._exos_membership_product_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', p.id, 'name', p.name, 'description', p.description, 'image_url', p.image_url,
    'price_cents', p.price_cents, 'currency', p.currency, 'billing', p.billing, 'duration_days', p.duration_days,
    'discount_percent', p.discount_percent, 'presale', p.presale, 'free_tickets_per_period', p.free_tickets_per_period,
    'guest_allowance', p.guest_allowance, 'household_seats', p.household_seats, 'giftable', p.giftable,
    'status', p.status, 'active', p.active, 'archived_at', p.archived_at, 'created_at', p.created_at,
    'updated_at', p.updated_at,
    'members_count', (SELECT count(*) FROM public.exos_fan_memberships m
                       WHERE m.product_id = p.id AND public._exos_membership_benefits_live(m)))
    FROM public.exos_membership_products p WHERE p.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_membership_product_json(uuid) FROM PUBLIC, anon, authenticated;

-- Create (p_id NULL; starts as a draft) or update. Unknown or read-only fields
-- are refused; billing and currency are set once; an archived product is not
-- edited. Names are unique among an org's live (not archived) products.
CREATE OR REPLACE FUNCTION public.exos_membership_product_save(p_org_id uuid, p_id uuid, p_fields jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c_edit CONSTANT text[] := ARRAY['name', 'description', 'image_url', 'price_cents', 'duration_days', 'discount_percent',
    'presale', 'free_tickets_per_period', 'guest_allowance', 'household_seats', 'giftable'];
  pr public.exos_membership_products%ROWTYPE; v_id uuid; v_f jsonb := coalesce(p_fields, '{}'::jsonb);
  v_name text;
BEGIN
  IF p_org_id IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'only an owner or manager can change membership products' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(v_f) <> 'object' THEN RAISE EXCEPTION 'the fields must be a JSON object' USING ERRCODE = '22023'; END IF;
  IF v_f ? 'name' THEN
    v_name := btrim(coalesce(v_f->>'name', ''));
    IF v_name = '' THEN RAISE EXCEPTION 'a membership product needs a name' USING ERRCODE = '22023'; END IF;
    v_f := v_f || jsonb_build_object('name', v_name);
  END IF;
  IF p_id IS NULL THEN
    IF v_name IS NULL THEN RAISE EXCEPTION 'a membership product needs a name' USING ERRCODE = '22023'; END IF;
    IF v_f ? 'currency' THEN v_f := v_f || jsonb_build_object('currency', lower(v_f->>'currency')); END IF;
    IF EXISTS (SELECT 1 FROM public.exos_membership_products x
                WHERE x.org_id = p_org_id AND x.status <> 'archived' AND lower(x.name) = lower(v_name)) THEN
      RAISE EXCEPTION 'there is already a membership product called %', v_name USING ERRCODE = '23505';
    END IF;
    v_id := public._exos_api_insert('public.exos_membership_products'::regclass, c_edit || ARRAY['billing', 'currency'],
      v_f, jsonb_build_object('org_id', p_org_id, 'created_by', auth.uid(), 'status', 'draft', 'active', false));
  ELSE
    SELECT * INTO pr FROM public.exos_membership_products WHERE id = p_id AND org_id = p_org_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'membership product not found' USING ERRCODE = 'P0002'; END IF;
    IF pr.status = 'archived' THEN
      RAISE EXCEPTION 'this membership product is archived and can''t be changed' USING ERRCODE = '55000';
    END IF;
    IF v_name IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_membership_products x
         WHERE x.org_id = p_org_id AND x.id <> pr.id AND x.status <> 'archived' AND lower(x.name) = lower(v_name)) THEN
      RAISE EXCEPTION 'there is already a membership product called %', v_name USING ERRCODE = '23505';
    END IF;
    -- Price and benefits apply to new members only (members keep their snapshot).
    PERFORM public._exos_api_update('public.exos_membership_products'::regclass, pr.id, c_edit, v_f);
    v_id := pr.id;
  END IF;
  RETURN public._exos_membership_product_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_product_save(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_product_save(uuid, uuid, jsonb) TO authenticated, service_role;

-- publish / unpublish / archive. Asking for the state it is already in is a
-- no-op (a retry is safe); anything out of the lifecycle is 55000.
CREATE OR REPLACE FUNCTION public.exos_membership_product_transition(p_id uuid, p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE pr public.exos_membership_products%ROWTYPE; v_to text;
BEGIN
  v_to := CASE p_action WHEN 'publish' THEN 'published' WHEN 'unpublish' THEN 'unpublished' WHEN 'archive' THEN 'archived' END;
  IF v_to IS NULL THEN RAISE EXCEPTION 'action must be publish, unpublish or archive' USING ERRCODE = '22023'; END IF;
  SELECT * INTO pr FROM public.exos_membership_products WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR NOT (public.exos_has_org_role(pr.org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'membership product not found' USING ERRCODE = 'P0002';
  END IF;
  IF pr.status <> v_to THEN
    IF pr.status = 'archived' THEN
      RAISE EXCEPTION 'this membership product is archived; archiving is final' USING ERRCODE = '55000';
    END IF;
    IF v_to = 'unpublished' AND pr.status = 'draft' THEN
      RAISE EXCEPTION 'a draft isn''t published yet' USING ERRCODE = '55000';
    END IF;
    UPDATE public.exos_membership_products SET status = v_to WHERE id = pr.id;
  END IF;
  RETURN public._exos_membership_product_json(pr.id);
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_product_transition(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_product_transition(uuid, text) TO authenticated, service_role;

-- The dashboard's products table (owner / manager / finance): every product
-- with its live-member count. Small per org, so the browser sorts and pages.
CREATE OR REPLACE FUNCTION public.exos_org_membership_products(p_org_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_org_id IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(public._exos_membership_product_json(p.id) ORDER BY p.created_at, p.id)
                     FROM public.exos_membership_products p WHERE p.org_id = p_org_id), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_membership_products(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_membership_products(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Memberships: issue, update, list (staff)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_membership_admin_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', m.id, 'product_id', m.product_id, 'product_name', m.product_name,
    'billing', m.billing, 'holder_email', m.holder_email, 'member_name', m.member_name,
    'has_account', m.holder_uid IS NOT NULL, 'status', m.status,
    'effective_status', public.exos_membership_effective_status(m.status, m.current_period_end),
    'current_period_start', m.current_period_start, 'current_period_end', m.current_period_end,
    'cancel_at_period_end', m.cancel_at_period_end, 'source', m.source, 'benefits', m.benefits,
    'ended_reason', m.ended_reason, 'stripe_billed', m.stripe_subscription_id IS NOT NULL,
    'staff_notes', m.staff_notes, 'issued_by', m.issued_by, 'created_at', m.created_at, 'updated_at', m.updated_at)
    FROM public.exos_fan_memberships m WHERE m.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_membership_admin_json(uuid) FROM PUBLIC, anon, authenticated;

-- A confirmed account with this email, if there is one.
CREATE OR REPLACE FUNCTION public._exos_confirmed_uid(p_email text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT u.id FROM auth.users u
   WHERE lower(u.email) = lower(btrim(p_email)) AND u.email_confirmed_at IS NOT NULL
   ORDER BY u.id LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_confirmed_uid(text) FROM PUBLIC, anon, authenticated;

-- Staff-issue a membership: { product_id, email, member_name?, source:
-- 'comp' (default) | 'import', expires_at?, staff_notes? }. Active at once,
-- with the product's benefits and a one-time term (expires_at, else one
-- period of the product). Refused when that email already holds a live
-- membership of the product. 30 a minute per member (exos_rate_hit).
CREATE OR REPLACE FUNCTION public.exos_membership_issue(p_org_id uuid, p_fields jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  f jsonb := coalesce(p_fields, '{}'::jsonb); pr public.exos_membership_products%ROWTYPE;
  v_email text; v_source text; v_end timestamptz; v_name text; v_notes text; v_uid uuid; v_id uuid; v_bad text;
BEGIN
  IF p_org_id IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'only an owner or manager can issue memberships' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(f) <> 'object' THEN RAISE EXCEPTION 'the fields must be a JSON object' USING ERRCODE = '22023'; END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(f) k
   WHERE k NOT IN ('product_id', 'email', 'member_name', 'source', 'expires_at', 'staff_notes') ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'unknown field: %', left(v_bad, 60) USING ERRCODE = '22023'; END IF;
  IF coalesce(f->>'product_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'product_id is required' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO pr FROM public.exos_membership_products WHERE id = (f->>'product_id')::uuid AND org_id = p_org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'membership product not found' USING ERRCODE = 'P0002'; END IF;
  IF pr.status = 'archived' THEN RAISE EXCEPTION 'this membership product is archived' USING ERRCODE = '55000'; END IF;
  v_email := lower(btrim(coalesce(f->>'email', '')));
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email) > 254 THEN
    RAISE EXCEPTION 'enter a valid email' USING ERRCODE = '22023';
  END IF;
  v_source := coalesce(nullif(f->>'source', ''), 'comp');
  IF v_source NOT IN ('comp', 'import') THEN RAISE EXCEPTION 'source must be comp or import' USING ERRCODE = '22023'; END IF;
  v_name := nullif(btrim(coalesce(f->>'member_name', '')), '');
  IF length(v_name) > 120 THEN RAISE EXCEPTION 'member_name is at most 120 characters' USING ERRCODE = '22023'; END IF;
  v_notes := nullif(btrim(coalesce(f->>'staff_notes', '')), '');
  IF length(v_notes) > 2000 THEN RAISE EXCEPTION 'staff_notes is at most 2000 characters' USING ERRCODE = '22023'; END IF;
  v_end := CASE WHEN nullif(f->>'expires_at', '') IS NOT NULL THEN (f->>'expires_at')::timestamptz
                ELSE now() + CASE pr.billing WHEN 'month' THEN interval '1 month' WHEN 'year' THEN interval '1 year'
                                             ELSE make_interval(days => pr.duration_days) END END;
  IF v_end <= now() OR v_end > now() + interval '10 years' THEN
    RAISE EXCEPTION 'expires_at must be in the next 10 years' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('mbr-issue:' || coalesce(auth.uid()::text, p_org_id::text), 30) THEN
    RAISE EXCEPTION 'too many memberships issued a minute' USING ERRCODE = '54000';
  END IF;
  -- One live membership of a product per email (serialised per product).
  PERFORM 1 FROM public.exos_membership_products WHERE id = pr.id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.exos_fan_memberships m
              WHERE m.product_id = pr.id AND lower(m.holder_email) = v_email
                AND (m.status = 'pending' OR public._exos_membership_benefits_live(m))) THEN
    RAISE EXCEPTION '% already has this membership', v_email USING ERRCODE = '23505';
  END IF;
  v_uid := public._exos_confirmed_uid(v_email);
  INSERT INTO public.exos_fan_memberships (org_id, product_id, product_name, billing, holder_uid, holder_email, status,
    current_period_start, current_period_end, benefits, source, member_name, staff_notes, issued_by)
  VALUES (pr.org_id, pr.id, pr.name, 'once', v_uid, v_email, 'active', now(), v_end,
    jsonb_build_object('discount_percent', pr.discount_percent, 'presale', pr.presale,
      'free_tickets_per_period', pr.free_tickets_per_period, 'guest_allowance', pr.guest_allowance,
      'household_seats', pr.household_seats,
      'term', CASE pr.billing WHEN 'month' THEN '1 month' WHEN 'year' THEN '1 year' ELSE pr.duration_days || ' days' END),
    v_source, v_name, v_notes, auth.uid())
  RETURNING id INTO v_id;
  BEGIN
    PERFORM public.exos_enqueue_webhook(pr.org_id, 'membership.created', jsonb_build_object('membership_id', v_id,
      'product_id', pr.id, 'billing', 'once', 'source', v_source, 'current_period_end', v_end));
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN public._exos_membership_admin_json(v_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_issue(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_issue(uuid, jsonb) TO authenticated, service_role;

-- Staff update: { member_name?, staff_notes?, status?: active | cancelled |
-- expired, expires_at? }. Status and the end date are staff's only for a
-- membership Stripe doesn't bill, that isn't a pending gift and has no
-- ended_reason (a refund is terminal). Cancel / expire end the benefits now.
CREATE OR REPLACE FUNCTION public.exos_membership_update(p_membership_id uuid, p_fields jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  f jsonb := coalesce(p_fields, '{}'::jsonb); m public.exos_fan_memberships%ROWTYPE; v_bad text;
  v_status text; v_end timestamptz; v_name text; v_notes text;
BEGIN
  SELECT * INTO m FROM public.exos_fan_memberships WHERE id = p_membership_id FOR UPDATE;
  IF NOT FOUND OR NOT (public.exos_has_org_role(m.org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'membership not found' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_typeof(f) <> 'object' THEN RAISE EXCEPTION 'the fields must be a JSON object' USING ERRCODE = '22023'; END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(f) k
   WHERE k NOT IN ('member_name', 'staff_notes', 'status', 'expires_at') ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'unknown or read-only field: %', left(v_bad, 60) USING ERRCODE = '22023'; END IF;
  v_name := CASE WHEN f ? 'member_name' THEN nullif(btrim(coalesce(f->>'member_name', '')), '') ELSE m.member_name END;
  IF length(v_name) > 120 THEN RAISE EXCEPTION 'member_name is at most 120 characters' USING ERRCODE = '22023'; END IF;
  v_notes := CASE WHEN f ? 'staff_notes' THEN nullif(btrim(coalesce(f->>'staff_notes', '')), '') ELSE m.staff_notes END;
  IF length(v_notes) > 2000 THEN RAISE EXCEPTION 'staff_notes is at most 2000 characters' USING ERRCODE = '22023'; END IF;
  v_status := m.status; v_end := m.current_period_end;
  IF f ? 'status' OR f ? 'expires_at' THEN
    IF m.ended_reason IS NOT NULL THEN
      RAISE EXCEPTION 'this membership ended for good (%): it can''t be changed', m.ended_reason USING ERRCODE = '55000';
    END IF;
    IF m.stripe_subscription_id IS NOT NULL THEN
      RAISE EXCEPTION 'Stripe bills this membership: change or cancel it through Stripe' USING ERRCODE = '55000';
    END IF;
    IF m.status = 'pending' THEN
      RAISE EXCEPTION 'this is an unclaimed gift: cancel the gift instead' USING ERRCODE = '55000';
    END IF;
    IF f ? 'expires_at' THEN
      v_end := (f->>'expires_at')::timestamptz;
      IF v_end IS NULL OR v_end > now() + interval '10 years' THEN
        RAISE EXCEPTION 'expires_at must be a date in the next 10 years' USING ERRCODE = '22023';
      END IF;
    END IF;
    IF f ? 'status' THEN
      v_status := f->>'status';
      IF v_status IS NULL OR v_status NOT IN ('active', 'cancelled', 'expired') THEN
        RAISE EXCEPTION 'status must be active, cancelled or expired' USING ERRCODE = '22023';
      END IF;
    END IF;
    IF v_status IN ('cancelled', 'expired') THEN
      v_end := least(coalesce(v_end, now()), now());
    ELSIF v_end IS NULL OR v_end <= now() THEN
      RAISE EXCEPTION 'an active membership needs an end date in the future' USING ERRCODE = '22023';
    END IF;
  END IF;
  UPDATE public.exos_fan_memberships
     SET member_name = v_name, staff_notes = v_notes, status = v_status, current_period_end = v_end,
         cancel_at_period_end = CASE WHEN v_status = 'active' THEN cancel_at_period_end ELSE false END
   WHERE id = m.id;
  BEGIN
    IF v_status = 'cancelled' AND m.status <> 'cancelled' THEN
      PERFORM public.exos_enqueue_webhook(m.org_id, 'membership.cancelled', jsonb_build_object('membership_id', m.id));
    END IF;
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN public._exos_membership_admin_json(m.id);
END $$;
REVOKE ALL ON FUNCTION public.exos_membership_update(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_membership_update(uuid, jsonb) TO authenticated, service_role;

-- The dashboard's members table: filter, sort, page. Owner / manager /
-- finance. p_status filters on the effective status (an active membership
-- past its end is 'expired'). Sorts: created_at, current_period_end,
-- holder_email, product_name, status. { total, rows }.
CREATE OR REPLACE FUNCTION public.exos_org_memberships_page(p_org_id uuid, p_status text DEFAULT NULL,
  p_product_id uuid DEFAULT NULL, p_search text DEFAULT NULL, p_sort text DEFAULT 'created_at', p_desc boolean DEFAULT true,
  p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_sort text; v_total int; v_rows jsonb; v_q text := nullif(btrim(coalesce(p_search, '')), '');
BEGIN
  IF p_org_id IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  v_sort := CASE p_sort WHEN 'current_period_end' THEN 'm.current_period_end' WHEN 'holder_email' THEN 'm.holder_email'
                        WHEN 'product_name' THEN 'm.product_name' WHEN 'status' THEN 'x.eff' ELSE 'm.created_at' END;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR coalesce(p_offset, 0) < 0 THEN
    RAISE EXCEPTION 'limit must be 1-200 and offset 0 or more' USING ERRCODE = '22023';
  END IF;
  IF v_q IS NOT NULL THEN v_q := '%' || replace(replace(replace(left(v_q, 100), '\', '\\'), '%', '\%'), '_', '\_') || '%'; END IF;
  EXECUTE format($q$
    WITH base AS (
      SELECT m.id, %1$s AS k, x.eff FROM public.exos_fan_memberships m
      CROSS JOIN LATERAL (SELECT public.exos_membership_effective_status(m.status, m.current_period_end) AS eff) x
       WHERE m.org_id = $1 AND ($2::text IS NULL OR x.eff = $2) AND ($3::uuid IS NULL OR m.product_id = $3)
         AND ($4::text IS NULL OR m.holder_email ILIKE $4 OR m.member_name ILIKE $4 OR m.product_name ILIKE $4))
    SELECT (SELECT count(*) FROM base),
           coalesce((SELECT jsonb_agg(public._exos_membership_admin_json(b.id) ORDER BY b.k %2$s NULLS LAST, b.id)
                       FROM (SELECT * FROM base ORDER BY k %2$s NULLS LAST, id LIMIT $5 OFFSET $6) b), '[]'::jsonb)
  $q$, v_sort, CASE WHEN coalesce(p_desc, true) THEN 'DESC' ELSE 'ASC' END)
  INTO v_total, v_rows USING p_org_id, nullif(p_status, ''), p_product_id, v_q, p_limit, coalesce(p_offset, 0);
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_memberships_page(uuid, text, uuid, text, text, boolean, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_memberships_page(uuid, text, uuid, text, text, boolean, integer, integer) TO authenticated, service_role;

-- Self: memberships staff issued to my confirmed email before I had an
-- account become mine (as exos_claim_my_passes does for passes). Gifts are
-- claimed with their token, never here.
CREATE OR REPLACE FUNCTION public.exos_claim_my_memberships()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_email text; n int;
BEGIN
  SELECT lower(u.email) INTO v_email FROM auth.users u WHERE u.id = auth.uid() AND u.email_confirmed_at IS NOT NULL;
  IF v_email IS NULL THEN RETURN 0; END IF;
  UPDATE public.exos_fan_memberships SET holder_uid = auth.uid()
   WHERE holder_uid IS NULL AND holder_email = v_email AND source IN ('comp', 'import') AND status <> 'pending'
     AND gift IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.exos_claim_my_memberships() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_claim_my_memberships() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Imported attendees (door imports)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_imported_attendee_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object('id', en.id, 'event_id', en.event_id, 'event_name', e.name, 'starts_at', e.starts_at,
    'list_id', en.list_id, 'list_name', l.name, 'guest_name', en.guest_name, 'email', en.email, 'phone', en.phone,
    'plus_ones', en.plus_ones, 'arrived', en.arrived, 'arrived_at', en.arrived_at, 'note', en.note,
    'code', en.external_code, 'ticket_label', en.ticket_label, 'source', en.source,
    'synced', en.external_ref IS NOT NULL, 'voided', en.voided_at IS NOT NULL,
    'created_at', en.created_at, 'updated_at', en.updated_at)
    FROM public.exos_guest_list_entries en
    JOIN public.exos_guest_lists l ON l.id = en.list_id
    JOIN public.exos_events e ON e.id = en.event_id
   WHERE en.id = p_id
$$;
REVOKE ALL ON FUNCTION public._exos_imported_attendee_json(uuid) FROM PUBLIC, anon, authenticated;

-- An imported row: one that came from another platform's export or sync.
CREATE OR REPLACE FUNCTION public._exos_guest_is_imported(en public.exos_guest_list_entries)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT en.source IS NOT NULL OR en.external_code IS NOT NULL OR en.external_ref IS NOT NULL
$$;
REVOKE ALL ON FUNCTION public._exos_guest_is_imported(public.exos_guest_list_entries) FROM PUBLIC, anon, authenticated;

-- The org's imported attendees (owner / manager): filter by event, source,
-- search (name, email, code); sort guest_name, created_at, event, source.
CREATE OR REPLACE FUNCTION public.exos_org_imported_attendees(p_org_id uuid, p_event_id uuid DEFAULT NULL,
  p_source text DEFAULT NULL, p_search text DEFAULT NULL, p_sort text DEFAULT 'created_at', p_desc boolean DEFAULT true,
  p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_sort text; v_total int; v_rows jsonb; v_q text := nullif(btrim(coalesce(p_search, '')), '');
BEGIN
  IF p_org_id IS NULL OR NOT (public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR coalesce(p_offset, 0) < 0 THEN
    RAISE EXCEPTION 'limit must be 1-200 and offset 0 or more' USING ERRCODE = '22023';
  END IF;
  v_sort := CASE p_sort WHEN 'guest_name' THEN 'lower(en.guest_name)' WHEN 'event' THEN 'e.starts_at'
                        WHEN 'source' THEN 'lower(en.source)' ELSE 'en.created_at' END;
  IF v_q IS NOT NULL THEN v_q := '%' || replace(replace(replace(left(v_q, 100), '\', '\\'), '%', '\%'), '_', '\_') || '%'; END IF;
  EXECUTE format($q$
    WITH base AS (
      SELECT en.id, %1$s AS k FROM public.exos_guest_list_entries en JOIN public.exos_events e ON e.id = en.event_id
       WHERE en.org_id = $1 AND public._exos_guest_is_imported(en)
         AND ($2::uuid IS NULL OR en.event_id = $2) AND ($3::text IS NULL OR lower(en.source) = lower($3))
         AND ($4::text IS NULL OR en.guest_name ILIKE $4 OR en.email ILIKE $4 OR en.external_code ILIKE $4))
    SELECT (SELECT count(*) FROM base),
           coalesce((SELECT jsonb_agg(public._exos_imported_attendee_json(b.id) ORDER BY b.k %2$s NULLS LAST, b.id)
                       FROM (SELECT * FROM base ORDER BY k %2$s NULLS LAST, id LIMIT $5 OFFSET $6) b), '[]'::jsonb)
  $q$, v_sort, CASE WHEN coalesce(p_desc, true) THEN 'DESC' ELSE 'ASC' END)
  INTO v_total, v_rows USING p_org_id, p_event_id, nullif(p_source, ''), v_q, p_limit, coalesce(p_offset, 0);
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_imported_attendees(uuid, uuid, text, text, text, boolean, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_org_imported_attendees(uuid, uuid, text, text, text, boolean, integer, integer) TO authenticated, service_role;

-- Load an imported row of the caller's org for a write (locked), or not found.
CREATE OR REPLACE FUNCTION public._exos_imported_attendee_for_write(p_id uuid)
RETURNS public.exos_guest_list_entries LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE en public.exos_guest_list_entries%ROWTYPE;
BEGIN
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR NOT public._exos_guest_is_imported(en)
     OR NOT (public.exos_has_org_role(en.org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin()) THEN
    RAISE EXCEPTION 'imported attendee not found' USING ERRCODE = 'P0002';
  END IF;
  IF en.external_ref IS NOT NULL THEN
    RAISE EXCEPTION 'this attendee is synced from %: change it there', split_part(en.external_ref, ':', 1) USING ERRCODE = '55000';
  END IF;
  RETURN en;
END $$;
REVOKE ALL ON FUNCTION public._exos_imported_attendee_for_write(uuid) FROM PUBLIC, anon, authenticated;

-- Edit: { guest_name?, email?, phone?, plus_ones?, note?, code?, ticket_label?,
-- source? }. Contact fields and plus-ones through exos_update_guest (its
-- caps); the code is normalized (_exos_door_code), unique per event, and
-- fixed once the party arrived; source can change, not be blanked.
CREATE OR REPLACE FUNCTION public.exos_imported_attendee_update(p_id uuid, p_fields jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE f jsonb := coalesce(p_fields, '{}'::jsonb); en public.exos_guest_list_entries%ROWTYPE; v_bad text; v_code text;
BEGIN
  en := public._exos_imported_attendee_for_write(p_id);
  IF jsonb_typeof(f) <> 'object' THEN RAISE EXCEPTION 'the fields must be a JSON object' USING ERRCODE = '22023'; END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(f) k
   WHERE k NOT IN ('guest_name', 'email', 'phone', 'plus_ones', 'note', 'code', 'ticket_label', 'source') ORDER BY k LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'unknown or read-only field: %', left(v_bad, 60) USING ERRCODE = '22023'; END IF;
  IF en.voided_at IS NOT NULL THEN RAISE EXCEPTION 'this attendee was voided' USING ERRCODE = '55000'; END IF;
  IF f ?| ARRAY['guest_name', 'email', 'phone', 'plus_ones', 'note'] THEN
    PERFORM public.exos_update_guest(en.id,
      CASE WHEN f ? 'guest_name' THEN f->>'guest_name' ELSE en.guest_name END,
      CASE WHEN f ? 'email' THEN f->>'email' ELSE en.email END,
      CASE WHEN f ? 'phone' THEN f->>'phone' ELSE en.phone END,
      CASE WHEN f ? 'plus_ones' THEN (f->>'plus_ones')::int ELSE en.plus_ones END,
      CASE WHEN f ? 'note' THEN f->>'note' ELSE en.note END);
  END IF;
  IF f ? 'code' THEN
    v_code := public._exos_door_code(f->>'code');
    IF nullif(btrim(coalesce(f->>'code', '')), '') IS NOT NULL AND v_code IS NULL THEN
      RAISE EXCEPTION 'code is at most 128 characters' USING ERRCODE = '22023';
    END IF;
    IF v_code IS DISTINCT FROM en.external_code AND en.arrived > 0 THEN
      RAISE EXCEPTION 'this party already checked in with its code' USING ERRCODE = '55000';
    END IF;
    IF v_code IS NULL AND en.source IS NULL AND NOT (f ? 'source' AND nullif(btrim(coalesce(f->>'source', '')), '') IS NOT NULL) THEN
      RAISE EXCEPTION 'an imported attendee keeps a code or a source' USING ERRCODE = '22023';
    END IF;
    IF v_code IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_guest_list_entries x
         WHERE x.event_id = en.event_id AND x.external_code = v_code AND x.id <> en.id) THEN
      RAISE EXCEPTION 'another attendee of this event has that code' USING ERRCODE = '23505';
    END IF;
    UPDATE public.exos_guest_list_entries SET external_code = v_code WHERE id = en.id;
  END IF;
  IF f ? 'ticket_label' THEN
    IF length(f->>'ticket_label') > 80 THEN RAISE EXCEPTION 'ticket_label is at most 80 characters' USING ERRCODE = '22023'; END IF;
    UPDATE public.exos_guest_list_entries SET ticket_label = nullif(btrim(coalesce(f->>'ticket_label', '')), '') WHERE id = en.id;
  END IF;
  IF f ? 'source' THEN
    IF nullif(btrim(coalesce(f->>'source', '')), '') IS NULL OR length(btrim(f->>'source')) > 40 THEN
      RAISE EXCEPTION 'source is 1-40 characters' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_guest_list_entries SET source = btrim(f->>'source') WHERE id = en.id;
  END IF;
  RETURN public._exos_imported_attendee_json(en.id);
END $$;
REVOKE ALL ON FUNCTION public.exos_imported_attendee_update(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_imported_attendee_update(uuid, jsonb) TO authenticated, service_role;

-- Delete one imported row (exos_remove_guest: not once the party arrived;
-- frees its place when the list counts toward capacity).
CREATE OR REPLACE FUNCTION public.exos_imported_attendee_delete(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE en public.exos_guest_list_entries%ROWTYPE;
BEGIN
  en := public._exos_imported_attendee_for_write(p_id);
  IF en.arrived > 0 THEN RAISE EXCEPTION 'this attendee already checked in' USING ERRCODE = '55000'; END IF;
  PERFORM public.exos_remove_guest(en.id);
  RETURN jsonb_build_object('id', en.id, 'deleted', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_imported_attendee_delete(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_imported_attendee_delete(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Season-pass wallet card (exos-wallet POST /season-pass)
-- ---------------------------------------------------------------------------
-- The holder's own active pass, holder-safe: no email, no price, no buyer id.
-- Not a door credential (tickets redeemed with the pass carry their own
-- codes), so the card has no barcode and nothing secret.
CREATE OR REPLACE FUNCTION public.exos_wallet_season_pass(p_pass_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_passes%ROWTYPE; v_org text; v_events jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'sign in' USING ERRCODE = '42501'; END IF;
  SELECT * INTO p FROM public.exos_passes WHERE id = p_pass_id AND holder_uid = auth.uid();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'record_not_found'); END IF;
  IF p.status <> 'active' OR (p.valid_until IS NOT NULL AND p.valid_until < now())
     OR (p.credits_total IS NOT NULL AND p.credits_used >= p.credits_total)
     OR (p.eligibility->>'date_to' IS NOT NULL AND (p.eligibility->>'date_to')::timestamptz < now()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wallet_pass_unavailable');
  END IF;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = p.org_id;
  SELECT coalesce(jsonb_agg(jsonb_build_object('name', e.name, 'starts_at', e.starts_at) ORDER BY e.starts_at), '[]'::jsonb)
    INTO v_events
    FROM (SELECT e.name, e.starts_at FROM public.exos_events e
           WHERE e.id IN (SELECT x::uuid FROM jsonb_array_elements_text(coalesce(p.eligibility->'event_ids', '[]')) x)
             AND e.org_id = p.org_id AND e.status = 'published' AND (e.starts_at IS NULL OR e.starts_at > now() - interval '1 day')
           ORDER BY e.starts_at NULLS LAST LIMIT 10) e;
  RETURN jsonb_build_object('ok', true, 'payload', jsonb_build_object(
    'serial', 'sp-' || p.id, 'pass_id', p.id, 'kind', p.kind, 'name', p.name, 'org_name', v_org,
    'credits_total', p.credits_total, 'credits_used', p.credits_used, 'per_event_limit', p.per_event_limit,
    'valid_until', p.valid_until, 'date_from', p.eligibility->>'date_from', 'date_to', p.eligibility->>'date_to',
    'events', v_events, 'updated_at', p.updated_at));
END $$;
REVOKE ALL ON FUNCTION public.exos_wallet_season_pass(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_wallet_season_pass(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. The partner API's commerce / import writes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_api_commerce_action_scope(p_action text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN p_action IN ('membership_product.create', 'membership_product.update', 'membership_product.publish',
                      'membership_product.unpublish', 'membership_product.archive',
                      'membership.issue', 'membership.update') THEN 'commerce:write'
    WHEN p_action IN ('migrated_attendee.update', 'migrated_attendee.delete') THEN 'tickets:write'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_api_commerce_action_scope(text) FROM PUBLIC, anon, authenticated;

-- exos_api_write's steps (20261031110000) for these actions: the key and its
-- org, the scope again, run as the key's creator while an active member, the
-- Idempotency-Key (claimed first, replayed after), the dashboard RPC, the log.
CREATE OR REPLACE FUNCTION public.exos_api_commerce_write(
  p_key_id uuid, p_action text, p_target text DEFAULT NULL, p_args jsonb DEFAULT '{}'::jsonb,
  p_idempotency_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  k public.exos_api_keys%ROWTYPE; v_org uuid; v_actor uuid; v_email text; v_scope text; v_log uuid;
  v_prev public.exos_api_writes%ROWTYPE; v_was jsonb; v_out jsonb; v_id uuid; a jsonb := coalesce(p_args, '{}'::jsonb);
BEGIN
  SELECT * INTO k FROM public.exos_api_keys WHERE id = p_key_id AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'exos_api_write: invalid or revoked API key' USING ERRCODE = '42501'; END IF;
  v_org := k.org_id;
  v_scope := public._exos_api_commerce_action_scope(p_action);
  IF v_scope IS NULL THEN RAISE EXCEPTION 'exos_api_write: unknown action' USING ERRCODE = '22023'; END IF;
  IF NOT public._exos_api_has_scope(k.scopes, v_scope) THEN
    RAISE EXCEPTION 'exos_api_write: the key lacks the % scope', v_scope USING ERRCODE = '42501';
  END IF;
  v_actor := k.created_by;
  IF v_actor IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
       WHERE m.org_id = v_org AND m.user_id = v_actor AND m.disabled IS NOT TRUE) THEN
    RAISE EXCEPTION 'exos_api_write: the member who created this key is no longer in the organization; create a new key'
      USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NOT NULL THEN
    IF p_idempotency_key !~ '^[A-Za-z0-9_.:-]{8,100}$' THEN
      RAISE EXCEPTION 'exos_api_write: Idempotency-Key must be 8-100 letters, digits, _ . : or -' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target, idempotency_key)
    VALUES (v_org, k.id, v_actor, p_action, left(p_target, 255), p_idempotency_key)
    ON CONFLICT (api_key_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
    RETURNING id INTO v_log;
    IF v_log IS NULL THEN
      SELECT * INTO v_prev FROM public.exos_api_writes WHERE api_key_id = k.id AND idempotency_key = p_idempotency_key;
      IF v_prev.action IS DISTINCT FROM p_action OR v_prev.target IS DISTINCT FROM left(p_target, 255) THEN
        RAISE EXCEPTION 'exos_api_write: this Idempotency-Key was already used for another request' USING ERRCODE = '22023';
      END IF;
      RETURN coalesce(v_prev.result, '{}'::jsonb) || jsonb_build_object('idempotent_replay', true);
    END IF;
  END IF;

  v_was := jsonb_build_object(
    'claims', current_setting('request.jwt.claims', true), 'sub', current_setting('request.jwt.claim.sub', true),
    'role', current_setting('request.jwt.claim.role', true), 'email', current_setting('request.jwt.claim.email', true));
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_actor;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_actor, 'role', 'authenticated',
    'email', coalesce(v_email, ''), 'exos_api_key_id', k.id)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_actor::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_email, ''), true);

  -- Every target is pinned to the key's org first (else not found).
  IF p_action = 'membership_product.create' THEN
    v_out := public.exos_membership_product_save(v_org, NULL, a);
  ELSIF p_action LIKE 'membership_product.%' THEN
    v_id := public._exos_api_uuid(p_target, 'membership product');
    IF NOT EXISTS (SELECT 1 FROM public.exos_membership_products WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: membership product not found' USING ERRCODE = 'P0002';
    END IF;
    v_out := CASE p_action WHEN 'membership_product.update' THEN public.exos_membership_product_save(v_org, v_id, a)
             ELSE public.exos_membership_product_transition(v_id, split_part(p_action, '.', 2)) END;
  ELSIF p_action = 'membership.issue' THEN
    v_out := public.exos_membership_issue(v_org, a);
  ELSIF p_action = 'membership.update' THEN
    v_id := public._exos_api_uuid(p_target, 'membership');
    IF NOT EXISTS (SELECT 1 FROM public.exos_fan_memberships WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: membership not found' USING ERRCODE = 'P0002';
    END IF;
    v_out := public.exos_membership_update(v_id, a);
  ELSE -- migrated_attendee.update / .delete
    v_id := public._exos_api_uuid(p_target, 'imported attendee');
    IF NOT EXISTS (SELECT 1 FROM public.exos_guest_list_entries WHERE id = v_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_api_write: imported attendee not found' USING ERRCODE = 'P0002';
    END IF;
    v_out := CASE p_action WHEN 'migrated_attendee.update' THEN public.exos_imported_attendee_update(v_id, a)
             ELSE public.exos_imported_attendee_delete(v_id) END;
  END IF;

  PERFORM set_config('request.jwt.claims', coalesce(v_was ->> 'claims', ''), true);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_was ->> 'sub', ''), true);
  PERFORM set_config('request.jwt.claim.role', coalesce(v_was ->> 'role', ''), true);
  PERFORM set_config('request.jwt.claim.email', coalesce(v_was ->> 'email', ''), true);

  IF v_log IS NOT NULL THEN
    UPDATE public.exos_api_writes SET result = v_out WHERE id = v_log;
  ELSE
    INSERT INTO public.exos_api_writes (org_id, api_key_id, actor, action, target)
    VALUES (v_org, k.id, v_actor, p_action, left(p_target, 255));
  END IF;
  RETURN coalesce(v_out, '{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_api_commerce_write(uuid, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_commerce_write(uuid, text, text, jsonb, text) TO service_role;
