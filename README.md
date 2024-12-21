# Epsilon Database

[Epsilon Edge Functions](https://github.com/stuysu/epsilon-database)

SQL queries used to set up the database (e.g. creation of tables, modifications
to the database schema, RLS, and database functions) must be saved here to
ensure that new developers can set up a complete instance of the Epsilon backend
from a fresh Supabase install.

This repository was created after the `CREATE_MEMBERSHIP_TABLE` SQL Query was
deleted because someone thought it was a table.

# Justification

- We can run sql files in Supabase's SQL editor (and self hosted Supabase
  doesn't save them)

- The alternative is to connect to Supabase's postgres database through Prisma
  and use a different notation to manage our database.

- This solution is simpler, for once the queries are recorded, they can be run
  once without any further issues.

- In the future, the database may be managed through javascript ORM

# Create buckets

- public-files (make it public)
- file size limit of 5MB

# Configuring the Database

To set up your Supabase database with the current schema and database functions,
execute all _**numbered**_ `.sql` files in the
[Epsilon Database](https://github.com/stuysu/epsilon-database) repository, in
numbered order, via the SQL query menu. (Hint: `cat 0*.sql` in most shells will
allow you to copy all the SQL code in one operation).

Files are prefixed with a number indicating the order that they must be run on
in order to ensure dependencies are satisfied,

# Environment Variables

## Supabase Dashboard Credentials

- DASHBOARD_USERNAME
- DASHBOARD_PASSWORD

## Secrets

Use the tools on the
[Supabase self-hosting guide](https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys)
to generate these

- JWT_SECRET
- ANON_KEY - Used for unauthenticated access to the Epsilon database
- SERVICE_ROLE_KEY

## Google sign ins

Refer to https://github.com/orgs/supabase/discussions/4885.

- set google auth settings to allow sign in with google
- ENABLE_GOOGLE_SIGNUP=true
- GOOGLE_CLIENT_ID=
- GOOGLE_CLIENT_SECRET=
- AUTH_REDIRECT=<domain>/auth/v1/callback (replace
  GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI with ${AUTH_REDIRECT} in compose file, and
  add any valid redirects to google console)

## Sending Emails (add these to .env file as well as supabase edge function environment in the docker compose file)

- NODEMAILER_EMAIL
- NODEMAILER_FROM
- NODEMAILER_PASSWORD
- NODEMAILER_HOST
- NODEMAILER_PORT
- NODEMAILER_SECURE

## Changing database password

The Postgres password cannot be changed via `.env` after initialization. Use
`./change_password.sh` instead.
