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
| `exos-*` edge functions + `stripe-webhook` (Exos fulfillment/refunds, no `exos-` prefix) | `Terminal-2/supabase/functions/` | `supabase/functions/`. Keep in step |
| `_shared/cron-auth.ts` | `Terminal-2/supabase/functions/_shared/` | vendored |
| SQL harnesses | `Terminal-2/tests/exos/` (its CI gates the shared DB) | `tests/exos/` (this repo's CI runs them too) |
| Built SPA bundle | `Terminal-2/static/bridge/` (served by `vibepass-storefront-test`) | build it here (`dist/`), copy it over |

The app source (`src/`, `server.ts`, etc.) lives **only** here now. It was
removed from Terminal-2.

When the DB split happens (plan step 4 below), flip this table: this repo becomes
authoritative and the Terminal-2 copies get deleted.

## Caveats

- These are only the migrations with `exos` in the filename. 18 Terminal-2
  migrations without `exos` in the name also alter `exos_*` objects, so
  replaying this directory from zero **does not** reproduce the production
  schema exactly. The ones that matter most:
  - `20260622200000_rls_initplan_optimization.sql` rewrites the exos RLS
    policies (`auth.uid()` → `(select auth.uid())`); **the final policy text is
    there, not in the exos migrations.**
  - `20260622190000_fk_indexes_unindexed.sql` adds exos FK indexes.
  - `20260526020000_fix_checkins_scanned_by_nullable.sql` changes `exos_checkins`.
  - security sweeps: `20260525170000_*`, `20260525180000_*`, `20260601120100_sec_p1_*`,
    `20260601120200_sec_p2_*`, `20260621180156_harden_pgcrypto_*`,
    `20260622180000_axs_security_lockdown.sql`, `20260623190100_flip_safe_definer_*`,
    `20260702140000_a1_security_close_*`.
  Find the full list with
  `grep -l exos_ Terminal-2/supabase/migrations/*.sql | grep -v exos`. Take a baseline `pg_dump --schema-only` of the `exos_*`
  objects when splitting off a dedicated project.
- `exos_*` tables live in `public`, not in their own schema. Their RLS uses the
  shared Supabase Auth.

The full split (new project, data copy, repointing the functions and the SPA)
is step 4 of Terminal-2's `docs/archive/2026-07-02-bridge-extraction-plan.md`
and hasn't been done yet.
