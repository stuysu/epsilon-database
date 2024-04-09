# Epsilon Database

Please save any useful / essential SQL queries here.

This repository was created after the CREATE_MEMBERSHIP_TABLE SQL Query was deleted because someone thought it was a table.

# TODO

- add policy that prevents rooms on the same day from being double booked

- prevent spaces from being at the start or ends of urls or else the organization url won't work

- validation for all data being entered 🥱

# why is this a thing?

- we can run sql files in supabase's sql editor (and self hosted supabase doesn't save them)

- otherwise, we would need to connect to supabase's postgres database through prisma and learn a whole new set of notation to manage our database

- this should be simpler, finish it, run it once, and never need to touch certain files ever again

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

DATABASE_FUNCS.sql

DATABASE_FUNC_PERMS.sql
