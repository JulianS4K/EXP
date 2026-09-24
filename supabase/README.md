# supabase/

Exos still runs on the **shared** Supabase project it has always used, alongside
Terminal-2's broker data. The code moved out of Terminal-2; the database has not.

## Where each thing lives until the database split

While the DB is shared, **Terminal-2 stays authoritative** for everything that
gets applied or deployed to that project. This directory is a history-carrying
copy so Exos can be read, tested and reasoned about on its own.

| Thing | Authoritative home (edit + apply/deploy from) | Copy here |
|---|---|---|
| `*exos*` migrations | `Terminal-2/supabase/migrations/` | `supabase/migrations/`. When you add one there, copy it here in the same change |
| `exos-*` edge functions | `Terminal-2/supabase/functions/` | `supabase/functions/`. Keep in step |
| `_shared/cron-auth.ts` | `Terminal-2/supabase/functions/_shared/` | vendored |
| SQL harnesses | `Terminal-2/tests/exos/` (its CI gates the shared DB) | `tests/exos/` (this repo's CI runs them too) |
| Built SPA bundle | `Terminal-2/static/bridge/` (served by `vibepass-storefront-test`) | build it here (`dist/`), copy it over |

The app source (`src/`, `server.ts`, etc.) lives **only** here now. It was
removed from Terminal-2.

When the DB split happens (plan step 4 below), flip this table: this repo becomes
authoritative and the Terminal-2 copies get deleted.

## Caveats

- These are only the migrations with `exos` in the filename. Some Terminal-2
  security sweeps (e.g. `*_sec_p*`, `*_rls_initplan_optimization`,
  `*_flip_safe_definer_views_security_invoker`) also touch `exos_*` objects, so
  replaying this directory from zero **does not** reproduce the production
  schema exactly. Take a baseline `pg_dump --schema-only` of the `exos_*`
  objects when splitting off a dedicated project.
- `exos_*` tables live in `public`, not in their own schema. Their RLS uses the
  shared Supabase Auth.

The full split (new project, data copy, repointing the functions and the SPA)
is step 4 of Terminal-2's `docs/archive/2026-07-02-bridge-extraction-plan.md`
and hasn't been done yet.
