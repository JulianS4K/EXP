# supabase/

Exos still runs on the **shared** Supabase project it has always used, alongside
Terminal-2's broker data. The code moved out of Terminal-2; the database has not.

## Where each thing lives until the database split

The DB is still shared with Terminal-2's broker data, but **all Exos
server-side source now lives here**: edge functions since 2026-09-26, and
migrations + SQL harnesses since 2026-09-26 as well. Terminal-2 no longer
carries copies.

| Thing | Authoritative home (edit + apply/deploy from) | Notes |
|---|---|---|
| Exos edge functions: `exos-*` + `stripe-webhook` | **This repo**, `supabase/functions/` | Deploy to the shared project |
| `_shared/cron-auth.ts` | **This repo** (the Exos copy) | Terminal-2 keeps its own for its broker functions |
| `*exos*` migrations | **This repo**, `supabase/migrations/` | Apply to the shared project; see the rules below |
| SQL harnesses | **This repo**, `tests/exos/` | CI runs them (`exos-sql` job, incl. the barcode-secret RLS test) |
| Built SPA bundle | `Terminal-2/static/bridge/` (served by `vibepass-storefront-test`) | build it here (`dist/`), copy it over |

Applying a migration or deploying a function still goes to the **same shared
project** and still needs explicit operator permission.

### Migration rules while the DB is shared

1. **Filenames contain `exos`** (CI enforces it). Terminal-2's prod drift
   check (`bin/sync-check.sh`) treats applied migrations with `exos` in the
   name as owned here, so they don't show up as drift there.
2. **Timestamps are shared with Terminal-2.** Both repos write the same
   `supabase_migrations.schema_migrations` history, and its `version` is the
   primary key. Before choosing a prefix, check Terminal-2's
   `supabase/migrations/` (and prod's history) for the same 14 digits. A
   collision can't corrupt anything, since the apply fails on the PK, but it
   has to be renamed.
3. **Cross-cutting sweeps stay in Terminal-2.** Eighteen Terminal-2
   migrations (security / RLS / index sweeps across the whole schema, e.g.
   `*_sec_p*`, `*_rls_initplan_optimization`, `*_fk_indexes_unindexed`) also
   touch `exos_*` objects. They're already applied and stay there as
   history, so replaying this directory alone doesn't reproduce prod
   exactly (see Caveats).

When the DB split happens (plan step 4 below), the remaining step is data:
a new project, a data copy, and repointing the functions and the SPA.

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
