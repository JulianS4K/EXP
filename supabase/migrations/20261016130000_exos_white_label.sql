-- ============================================================================
-- White-label: venue site pages and custom domains
-- ============================================================================
-- Touches:  W: TABLE exos_orgs (+ site jsonb)
--           W: VIEW exos_public_orgs (+ site)
--           C: TABLE exos_org_domains; VIEW exos_public_org_domains (verified
--              domain -> org slug, public)
--           C: FUNCTION exos_set_org_site, exos_add_org_domain,
--              exos_remove_org_domain, exos_list_org_domains (owner /
--              manager), exos_mark_org_domain, exos_org_domain_token
--              (service role)
-- Pre-reqs: the org tables and exos_public_orgs
--
-- Site pages: the org storefront (/o/:slug) renders `site.sections` in order
-- when set: hero, events, about, text, faq, gallery, links, newsletter. Text is
-- plain (rendered with the store page's safe markdown), links https only;
-- the shape is checked here, the rendering escapes everything.
--
-- Custom domains (tickets.venue.com): an owner / manager adds the domain and
-- gets a token. They point the domain at the Exos web host (CNAME) and add a
-- TXT record _exos-verify.<domain> = <token>; exos-integrations /verify-domain
-- checks the TXT record and marks it verified. Verified domains: the web
-- server sends their root to the org's storefront, and Stripe checkout may
-- return to them. TLS for the domain is the host's job (Render custom domains).
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS site jsonb;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_orgs_site_chk') THEN
    ALTER TABLE public.exos_orgs ADD CONSTRAINT exos_orgs_site_chk
      CHECK (site IS NULL OR (jsonb_typeof(site) = 'object' AND length(site::text) <= 30000));
  END IF;
END $$;

-- Shape check for a site: {"sections": [{type, ...}]}, at most 20 sections;
-- string fields only, capped; urls https.
CREATE OR REPLACE FUNCTION public._exos_site_error(p_site jsonb)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE s jsonb; k text; v jsonb; it jsonb; n int := 0;
BEGIN
  IF p_site IS NULL THEN RETURN NULL; END IF;
  IF jsonb_typeof(p_site) <> 'object' OR length(p_site::text) > 30000 THEN RETURN 'the site is too big'; END IF;
  IF jsonb_typeof(coalesce(p_site->'sections', '[]'::jsonb)) <> 'array' THEN RETURN 'sections must be a list'; END IF;
  FOR s IN SELECT value FROM jsonb_array_elements(coalesce(p_site->'sections', '[]'::jsonb)) LOOP
    n := n + 1;
    IF n > 20 THEN RETURN 'at most 20 sections'; END IF;
    IF jsonb_typeof(s) <> 'object' OR coalesce(s->>'type', '') NOT IN ('hero', 'events', 'about', 'text', 'faq', 'gallery', 'links', 'newsletter') THEN
      RETURN 'unknown section ' || n;
    END IF;
    FOR k, v IN SELECT key, value FROM jsonb_each(s) LOOP
      IF k = 'items' THEN
        IF jsonb_typeof(v) <> 'array' OR jsonb_array_length(v) > 30 THEN RETURN 'section ' || n || ': at most 30 items'; END IF;
        FOR it IN SELECT value FROM jsonb_array_elements(v) LOOP
          IF jsonb_typeof(it) <> 'object' OR EXISTS (
               SELECT 1 FROM jsonb_each(it) x
                WHERE jsonb_typeof(x.value) <> 'string' OR length(x.value #>> '{}') > 2000
                   OR (x.key IN ('url', 'image') AND x.value #>> '{}' !~ '^https://[^\s<>"]+$')) THEN
            RETURN 'section ' || n || ': bad item';
          END IF;
        END LOOP;
      ELSIF jsonb_typeof(v) <> 'string' OR length(v #>> '{}') > 4000 THEN
        RETURN 'section ' || n || ': ' || k || ' must be text under 4000 characters';
      ELSIF k IN ('url', 'image', 'button_url') AND v #>> '{}' !~ '^https://[^\s<>"]+$' THEN
        RETURN 'section ' || n || ': ' || k || ' must be an https link';
      END IF;
    END LOOP;
  END LOOP;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.exos_set_org_site(p_org_id uuid, p_site jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_err text := public._exos_site_error(p_site);
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_set_org_site: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION 'exos_set_org_site: %', v_err USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_orgs SET site = p_site WHERE id = p_org_id;
  RETURN coalesce(p_site, 'null'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_org_site(uuid, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_org_site(uuid, jsonb) TO authenticated, service_role;

-- The public org view carries the site (what the storefront renders).
DO $$
DECLARE d text; opts text; i int;
BEGIN
  IF to_regclass('public.exos_public_orgs') IS NULL THEN
    RAISE NOTICE 'exos_public_orgs: view not present here, skipping';
    RETURN;
  END IF;
  d := pg_get_viewdef('public.exos_public_orgs'::regclass);
  IF d ~ '\msite\M' THEN
    RAISE NOTICE 'exos_public_orgs: already has site, skipping';
    RETURN;
  END IF;
  i := position(E'\n   FROM ' in d);
  IF i = 0 THEN
    RAISE EXCEPTION 'exos_public_orgs: unexpected view definition';
  END IF;
  d := left(d, i - 1) || ',
    site' || substr(d, i);
  SELECT coalesce(' WITH (' || array_to_string(c.reloptions, ', ') || ')', '') INTO opts
    FROM pg_class c WHERE c.oid = 'public.exos_public_orgs'::regclass;
  EXECUTE format('CREATE OR REPLACE VIEW public.exos_public_orgs%s AS %s', opts, d);
  GRANT SELECT ON public.exos_public_orgs TO anon, authenticated;
END $$;

-- ---------------------------------------------------------------------------
-- Custom domains
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_org_domains (
  domain          text PRIMARY KEY CHECK (domain ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' AND length(domain) <= 253),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'verified', 'failed')),
  verify_token    text NOT NULL DEFAULT encode(extensions.gen_random_bytes(16), 'hex'),
  created_by      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  verified_at     timestamptz,
  last_checked_at timestamptz,
  last_error      text CHECK (last_error IS NULL OR length(last_error) <= 200)
);
CREATE INDEX IF NOT EXISTS exos_org_domains_org_idx ON public.exos_org_domains (org_id);
ALTER TABLE public.exos_org_domains ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_org_domains FROM PUBLIC, anon, authenticated;

-- Public: which verified domain belongs to which storefront (DNS says so anyway).
CREATE OR REPLACE VIEW public.exos_public_org_domains
WITH (security_barrier = true)
AS
SELECT d.domain, o.slug AS org_slug, d.org_id
  FROM public.exos_org_domains d
  JOIN public.exos_orgs o ON o.id = d.org_id
 WHERE d.status = 'verified';
GRANT SELECT ON public.exos_public_org_domains TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_add_org_domain(p_org_id uuid, p_domain text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_domain text := lower(btrim(regexp_replace(coalesce(p_domain, ''), '^https?://|/.*$', '', 'g')));
  d public.exos_org_domains%ROWTYPE;
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_add_org_domain: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF v_domain !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' OR length(v_domain) > 253 THEN
    RAISE EXCEPTION 'exos_add_org_domain: give a domain like tickets.yourvenue.com' USING ERRCODE = '22023';
  END IF;
  IF v_domain ~ '(^|\.)(onrender\.com|supabase\.co|exos\.live|localhost)$' THEN
    RAISE EXCEPTION 'exos_add_org_domain: use a domain you own' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO d FROM public.exos_org_domains WHERE domain = v_domain;
  IF FOUND AND d.org_id <> p_org_id THEN
    RAISE EXCEPTION 'exos_add_org_domain: that domain is used by another organizer' USING ERRCODE = '23505';
  END IF;
  IF NOT FOUND THEN
    IF (SELECT count(*) FROM public.exos_org_domains WHERE org_id = p_org_id) >= 3 THEN
      RAISE EXCEPTION 'exos_add_org_domain: at most 3 domains' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.exos_org_domains (domain, org_id, created_by) VALUES (v_domain, p_org_id, auth.uid())
    RETURNING * INTO d;
  END IF;
  RETURN jsonb_build_object('domain', d.domain, 'status', d.status, 'txt_name', '_exos-verify.' || d.domain, 'txt_value', d.verify_token);
END $$;
REVOKE ALL ON FUNCTION public.exos_add_org_domain(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_add_org_domain(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_remove_org_domain(p_org_id uuid, p_domain text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_remove_org_domain: owner or manager only' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_org_domains WHERE org_id = p_org_id AND domain = lower(btrim(p_domain));
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_remove_org_domain(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_remove_org_domain(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_list_org_domains(p_org_id uuid)
RETURNS TABLE (domain text, status text, txt_name text, txt_value text, verified_at timestamptz, last_checked_at timestamptz, last_error text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF coalesce(public._exos_integ_role(p_org_id, auth.uid()), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'exos_list_org_domains: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT d.domain, d.status, '_exos-verify.' || d.domain, d.verify_token, d.verified_at, d.last_checked_at, d.last_error
    FROM public.exos_org_domains d WHERE d.org_id = p_org_id ORDER BY d.created_at;
END $$;
REVOKE ALL ON FUNCTION public.exos_list_org_domains(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_list_org_domains(uuid) TO authenticated, service_role;

-- Service role: the token to look for, and the result of the DNS check.
CREATE OR REPLACE FUNCTION public.exos_org_domain_token(p_org_id uuid, p_domain text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT verify_token FROM public.exos_org_domains WHERE org_id = p_org_id AND domain = lower(btrim(p_domain)) $$;
REVOKE ALL ON FUNCTION public.exos_org_domain_token(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_org_domain_token(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_mark_org_domain(p_domain text, p_ok boolean, p_error text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_org_domains
     SET status = CASE WHEN p_ok THEN 'verified' WHEN status = 'verified' THEN 'verified' ELSE 'failed' END,
         verified_at = CASE WHEN p_ok THEN coalesce(verified_at, now()) ELSE verified_at END,
         last_checked_at = now(),
         last_error = CASE WHEN p_ok THEN NULL ELSE left(p_error, 200) END
   WHERE domain = lower(btrim(p_domain))
  RETURNING true
$$;
REVOKE ALL ON FUNCTION public.exos_mark_org_domain(text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_mark_org_domain(text, boolean, text) TO service_role;

-- ROLLBACK (manual): drop the view exos_public_org_domains, the functions above,
-- exos_org_domains; re-create exos_public_orgs without site; drop exos_orgs.site.
