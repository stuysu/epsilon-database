-- "Enable all access to site admins" on public.users checked is_admin(id),
-- i.e. whether the row being changed belongs to a site admin, not whether
-- the caller is one. Any signed-in user could therefore update or delete a
-- site admin's row (including changing its email to their own, which then
-- made them a site admin). Check the caller instead.
--
-- The lookup runs in a SECURITY DEFINER function so it can read users
-- without re-entering this table's RLS (which would recurse).

CREATE OR REPLACE FUNCTION public.caller_is_site_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users u
        JOIN public.permissions p ON p.user_id = u.id
        WHERE u.email = (auth.jwt() ->> 'email')
          AND p.permission = 'ADMIN'
    );
$$;

REVOKE ALL ON FUNCTION public.caller_is_site_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.caller_is_site_admin() TO authenticated;

DROP POLICY IF EXISTS "Enable all access to site admins" ON public.users;

CREATE POLICY "Enable all access to site admins"
ON public.users
FOR ALL
TO authenticated
USING (public.caller_is_site_admin())
WITH CHECK (public.caller_is_site_admin());
