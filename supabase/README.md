# supabase/

Exos still runs on the **shared** Supabase project it has always used, alongside
Terminal-2's broker data. The code moved out of Terminal-2; the database has not.

## Where each thing lives until the database split

| Thing | Where you edit it | Where it's applied/deployed from |
|---|---|---|
| New `exos_*` migrations | **here** (`supabase/migrations/`) | applied to the shared project under operator direction; also mirrored into `Terminal-2/supabase/migrations/` so its migration history stays complete |
| Existing `*exos*` migrations | read-only history, don't edit | already applied |
| `exos-*` edge functions | **here** | deployed to the shared project |
| `_shared/cron-auth.ts` | vendored copy of `Terminal-2/supabase/functions/_shared/cron-auth.ts`; keep them in step | — |

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
