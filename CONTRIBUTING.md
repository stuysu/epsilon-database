# Contributing Guide -- Epsilon Functions

At this time, StuySU IT is **not** accepting external contributions. The
following documentation is meant for Directors.

## Development Stack

These SQL files are written in PL/pgSQL for the PostgresSQL server that Supabase
serves as a wrapper for.

## Editing Process

If you are only editing or querying row data, do so via an Epsilon client or the
Supabase dashboard. This repository is for schema, row-level security, and
database function changes.

1. Create a _**new**_ file and implement any breaking changes (to the schema,
   RLS, etc.) that you are going to make.
2. If your changes modify features of the database defined in previous files,
   please take care to leave a comment on a new line adjacent to the obsoleted
   code. This is the _**only**_ acceptable modification to existing files.
3. Test your changes against a local Supabase instance by running the new SQL
   code in the SQL Query menu (or similar). Ensure that database functions, edge
   functions, and client interactions with the affected elements of the database
   work correctly.
4. Verify your changes one last time with `git diff`, then commit and push the
   changes.
5. Run your new, working, script, on the production server.
