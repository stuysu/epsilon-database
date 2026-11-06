-- Let co-leads (ADMIN members) edit their organization while it is still
-- PENDING, not just the CREATOR. Previously an ADMIN's PATCH matched no rows
-- (200 []), so the edit was silently dropped.
--
-- Only the role check changes. Everything else is kept from the live policy:
--   * USING: the existing row must be PENDING, so approved/locked orgs are
--     still edited through organizationedits + site-admin approval.
--   * WITH CHECK: the new row must still be PENDING, so a co-lead (or the
--     creator) cannot change state to approve their own organization.
-- The caller's membership must also be active. Every CREATOR/ADMIN membership
-- on prod is active, so this does not take access away from anyone.

DROP POLICY IF EXISTS "Allow authenticated users to update pending organizations" ON public.organizations;

CREATE POLICY "Allow authenticated users to update pending organizations"
ON public.organizations
FOR UPDATE
USING (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships AS m ON (m.user_id = u.id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.role IN ('CREATOR', 'ADMIN')
      AND m.active = true
      AND public.organizations.id = m.organization_id
    )
  )
  AND public.organizations.state = 'PENDING'
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships AS m ON (m.user_id = u.id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.role IN ('CREATOR', 'ADMIN')
      AND m.active = true
      AND public.organizations.id = m.organization_id
    )
  )
  AND public.organizations.state = 'PENDING'
);
