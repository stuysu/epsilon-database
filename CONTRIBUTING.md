# Contributing Guide -- Epsilon Database

At this time, StuySU IT is **not** accepting external contributions. The
following documentation is meant for Directors.

This repository is for schema, row-level security and database function
changes. Edit row data through Epsilon or Studio instead.

## Rules

- **Never edit a migration that has run on production.** Fix things in a new,
  higher-numbered file. Applied files are listed in `public.schema_migrations`.
  (Exception: 051 was edited once to write `auth.jwt()` for `jwt()`, which only
  matters for replays; prod needs nothing.)
- **One number, one file.** Take the next free number and say in your PR which
  number you took, so parallel branches don't collide. CI fails on duplicates.
- Make files safe to re-run where you can (`IF NOT EXISTS`, `CREATE OR REPLACE`,
  `DROP POLICY IF EXISTS`).
- Don't put `COMMIT`/`ROLLBACK` in the middle of a file. A `BEGIN;` at the top
  and `COMMIT;` at the end are fine; the apply script replaces them with its own.

## Numbering gaps

- 043–046 were never merged on their own; that work was folded into 050 and 051.
- 053 was dropped (obsolete).
- 055 (SU Applications) and 056 (SU Votes) are reserved for branches that
  haven't merged yet.

## Making a change

1. Write a new `NNN_SHORT_NAME.sql`.
2. Try it on a local stack (see the site repo's `docs/local-setup.md`):

   ```sh
   scripts/apply-migration.sh --dry-run NNN_SHORT_NAME.sql   # runs, then ROLLBACK
   scripts/apply-migration.sh NNN_SHORT_NAME.sql             # applies and records it
   ```

   Check that the site and functions that use the changed tables still work.
3. Open a PR. CI replays every migration on a fresh Supabase Postgres and loads
   `POPULATE_DATABASE.sql`, so broken SQL or a file that depends on something
   only your local database has will fail there.

## Applying to production

Run everything as `supabase_admin`. The Studio SQL editor runs as `postgres`,
which doesn't own most tables.

`scripts/apply-migration.sh` wraps the file in one transaction, refuses if the
version is already recorded, and records it in `public.schema_migrations` when
it commits. `--dry-run` does the same but ends with `ROLLBACK`.

```sh
DB_SSH=<user>@<droplet> DB_CONTAINER=supabase-db \
  scripts/apply-migration.sh --dry-run NNN_SHORT_NAME.sql
DB_SSH=<user>@<droplet> DB_CONTAINER=supabase-db \
  scripts/apply-migration.sh NNN_SHORT_NAME.sql
```

`DATABASE_URL=postgres://supabase_admin:...@host:5432/postgres` works instead
of `DB_SSH`. Without either, the script targets the local container
`supabase_db_localsb`.

The first time, apply `057_AUDIT_FIXES.sql` this way. It creates the table
and records 001–054 as already applied.

Deploy order for a release: **database → functions → site**. See the site
repo's `docs/release-checklist.md`.
