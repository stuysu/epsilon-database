# Epsilon Database

Please save any useful / essential SQL queries here.

This repository was created after the CREATE_MEMBERSHIP_TABLE SQL Query was deleted because someone thought it was a table.

# why is this a thing?

- we can run sql files in supabase's sql editor (and self hosted supabase doesn't save them)

- otherwise, we would need to connect to supabase's postgres database through prisma and learn a whole new set of notation to manage our database

- this should be simpler, finish it, run it once, and never need to touch certain files ever again

- in the future, manage database through javascript ORM

# create buckets

- public-files (make it public)

# order of running files (some depend on others)

CREATE_USER_TABLE.sql

CREATE_ORG_TABLE.sql

CREATE_PERMISSIONS_TABLE.sql

CREATE_ROOMS_TABLE.sql

CREATE_MEMBERSHIP_TABLE.sql

CREATE_MEETINGS_TABLE.sql

CREATE_ORG_POLICY.sql

CREATE_POSTS_TABLE.sql

CREATE_ORG_EDITS_TABLE.sql

CREATE_STRIKES_TABLE.sql

CREATE_SETTINGS_TABLE.sql

CREATE_ORG_MESSAGES.sql

DATABASE_FUNCS.sql

DATABASE_FUNC_PERMS.sql

STORAGE_PERMS.sql

# supabase env

- DASHBORD_USERNAME <- set for supabase dashboard sign in
- DASHBOARD_PASSWORD
- JWT_SECRET <- create one from supabase website (they have a convenient ui for it)
- ANON_KEY <- use secret to make this from supabase site (update frontend with this anon key or else there will be errors)
- SERVICE_ROLE_KEY <- use secret to make this from supabase site

## Google sign ins
- set google auth settings to allow sign in with google
- ENABLE_GOOGLE_SIGNUP=true
- GOOGLE_CLIENT_ID=
- GOOGLE_CLIENT_SECRET=

## Sending Emails (add these to .env file as well as supabase edge function environment in the docker compose file)
- NODEMAILER_EMAIL=
- NODEMAILER_FROM=
- NODEMAILER_PASSWORD=
- NODEMAILER_HOST=
- NODEMAILER_PORT=
- NODEMAILER_SECURE=
