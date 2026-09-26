# supabase/

Exos still runs on the **shared** Supabase project it has always used, alongside
Terminal-2's broker data. The code moved out of Terminal-2; the database has not.

## Where each thing lives until the database split

The DB is still shared. As of 2026-09-26 the **edge functions moved here**;
everything that changes the database itself stays authored in Terminal-2.

| Thing | Authoritative home (edit + apply/deploy from) | Copy elsewhere |
|---|---|---|
| Exos edge functions: `exos-*` + `stripe-webhook` | **This repo**, `supabase/functions/` | None. Removed from Terminal-2 |
| `_shared/cron-auth.ts` | **This repo** (the Exos copy) | Terminal-2 keeps its own for its broker functions |
| `*exos*` migrations | `Terminal-2/supabase/migrations/` | `supabase/migrations/`. When you add one there, copy it here in the same change |
| SQL harnesses | `Terminal-2/tests/exos/` (its CI gates the shared DB) | `tests/exos/` (this repo's CI runs them too) |
| Built SPA bundle | `Terminal-2/static/bridge/` (served by `vibepass-storefront-test`) | build it here (`dist/`), copy it over |

The app source (`src/`, `server.ts`, etc.) and the Exos edge functions live
**only** here. Deploying a function is unchanged: it goes to the same shared
project and still needs explicit operator permission. Deploy from this repo
(`supabase functions deploy <name> --project-ref <ref>`, or the Supabase MCP
`deploy_edge_function`). Terminal-2's `bin/sync-check.sh` knows these
functions live here (`bin/sync-check-external-fns.txt`), so their prod
deployments don't read as drift there.

When the DB split happens (plan step 4 below), move the migrations and SQL
harnesses too, and delete the Terminal-2 copies.

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
