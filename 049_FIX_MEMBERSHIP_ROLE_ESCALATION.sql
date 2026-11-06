-- Stops organization admins from promoting their own membership to CREATOR.
-- The admin update policy let an admin edit their own row (so they can change
-- their role name or step down), but the new-row check used the same "own row"
-- exception, so it never restricted the new role. An admin could PATCH their own
-- membership to role = 'CREATOR' and then, through the creator policy, demote
-- the real creator. Admins can now never write CREATOR, and can only write ADMIN
-- on their own row (keeping their current role). Everything else admins could do
-- before is unchanged; only the creator policy can grant ADMIN or CREATOR.
-- The old policy name was truncated to 63 characters by Postgres (note the
-- trailing space), so it is dropped by that exact name.
DROP POLICY IF EXISTS "Enable regular membership update access to organization admins " ON public.memberships;
DROP POLICY IF EXISTS "Enable membership update access to organization admins" ON public.memberships;

CREATE POLICY "Enable membership update access to organization admins"
ON public.memberships
FOR UPDATE
TO authenticated
USING (
  (organization_id IN (SELECT get_user_admin_organizations()))
  AND (
    (role <> 'ADMIN' AND role <> 'CREATOR')
    OR (EXISTS (
      SELECT 1
      FROM users AS u
      WHERE (
        (u.email = (auth.jwt() ->> 'email'))
        AND (memberships.user_id = u.id)
      )
    ))
  )
)
WITH CHECK (
  (organization_id IN (SELECT get_user_admin_organizations()))
  AND (role <> 'CREATOR')
  AND (
    (role <> 'ADMIN')
    OR (EXISTS (
      SELECT 1
      FROM users AS u
      WHERE (
        (u.email = (auth.jwt() ->> 'email'))
        AND (memberships.user_id = u.id)
      )
    ))
  )
);
