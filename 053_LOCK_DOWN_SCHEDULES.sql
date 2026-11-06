-- The schedules table had row level security turned off, and the anon and
-- authenticated roles could insert, update, delete and truncate it. Anyone with
-- the public anon key could rewrite or wipe the bell schedules that the
-- fetch-schedule function serves.
--
-- Reads stay public, since fetch-schedule queries this table with the anon
-- key. Writes are left to service_role and postgres (the dashboard and SQL
-- editor). Safe to run more than once.
ALTER TABLE public.schedules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable read access to everyone" ON public.schedules;

CREATE POLICY "Enable read access to everyone"
ON public.schedules
FOR SELECT
TO anon, authenticated
USING (true);

REVOKE ALL ON public.schedules FROM anon, authenticated;
GRANT SELECT ON public.schedules TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
