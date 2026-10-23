-- Undoes 041_ALLOW_ANON_VIEW_LEADERS.sql. Anonymous visitors can no longer see
-- club leaders or member counts, which puts users and memberships back to
-- needing a signed-in account. Safe to run more than once.
DROP POLICY IF EXISTS "Enable anonymous read access to club leaders"
ON public.users;

DROP POLICY IF EXISTS "Enable anonymous read access to leader memberships"
ON public.memberships;

REVOKE SELECT ON public.users FROM anon;
GRANT SELECT ON public.users TO anon;

REVOKE SELECT ON public.memberships FROM anon;
GRANT SELECT ON public.memberships TO anon;

DROP FUNCTION IF EXISTS public.get_organization_member_counts(INT[]);

NOTIFY pgrst, 'reload schema';
