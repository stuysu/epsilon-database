-- Anonymous visitors can see the creator and admins of every publicly listed
-- club (everything except pending and punished clubs), limited to name, picture
-- and role. Emails, faculty status, grad year and every other user stay hidden
-- from them. Signed-in users are not affected.
REVOKE SELECT ON public.users FROM anon;
GRANT SELECT (id, first_name, last_name, picture) ON public.users TO anon;

REVOKE SELECT ON public.memberships FROM anon;
GRANT SELECT (id, organization_id, user_id, role, role_name, ordering_id, active)
ON public.memberships TO anon;

CREATE POLICY "Enable anonymous read access to leader memberships"
ON public.memberships
FOR SELECT
TO anon
USING (
  active = true
  AND (role = 'CREATOR' OR role = 'ADMIN')
  AND EXISTS (
    SELECT 1
    FROM public.organizations AS o
    WHERE (
      o.id = public.memberships.organization_id
      AND o.state NOT IN ('PENDING', 'PUNISHED')
    )
  )
);

CREATE POLICY "Enable anonymous read access to club leaders"
ON public.users
FOR SELECT
TO anon
USING (
  EXISTS (
    SELECT 1
    FROM public.memberships AS m
    WHERE m.user_id = public.users.id
  )
);

-- Member counts for publicly listed clubs, so anonymous visitors can see how
-- many members a club has without being able to read any membership.
CREATE OR REPLACE FUNCTION public.get_organization_member_counts(org_ids INT[])
RETURNS TABLE (organization_id INT, member_count BIGINT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT m.organization_id, count(*) AS member_count
  FROM public.memberships AS m
  INNER JOIN public.organizations AS o ON (o.id = m.organization_id)
  WHERE (
    m.active = true
    AND m.organization_id = ANY (org_ids)
    AND o.state NOT IN ('PENDING', 'PUNISHED')
  )
  GROUP BY m.organization_id;
$$;

REVOKE ALL ON FUNCTION public.get_organization_member_counts(INT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_organization_member_counts(INT[]) TO anon, authenticated;
