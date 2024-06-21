CREATE OR REPLACE FUNCTION user_has_pending_organization(user_email text)
RETURNS boolean AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM organizations o
    JOIN users u ON o.creator_id = u.id
    WHERE u.email = user_email
    AND o.state = 'PENDING'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE POLICY "Allow authenticated users to create pending organizations"
ON public.organizations
FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (u.email = (auth.jwt() ->> 'email'))
  )
  /* Don't allow users to create an organization if they already have one pending */
  AND NOT user_has_pending_organization(auth.jwt() ->> 'email')
  AND public.organizations.state = 'PENDING'
);

CREATE POLICY "Allow authenticated users to update pending organizations"
ON public.organizations
FOR UPDATE
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships as m ON (m.user_id = u.id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.role = 'CREATOR'
      AND public.organizations.id = m.organization_id
    )
  )
  AND state = 'PENDING'
);

CREATE POLICY "Allow authenticated users to delete their own organization"
ON public.organizations
FOR DELETE
USING (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships as m ON (m.user_id = u.id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.role = 'CREATOR'
      AND public.organizations.id = m.organization_id
    )
  )
);

CREATE POLICY "Enable all access to site admins"
ON public.organizations
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM permissions as p
    INNER JOIN users as u ON (p.user_id = u.id)
    WHERE (
      u.email = auth.jwt() ->> 'email'
      AND ( -- roles here
        p.permission = 'ADMIN'
      )
    )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM permissions as p
    INNER JOIN users as u ON (p.user_id = u.id)
    WHERE (
      u.email = auth.jwt() ->> 'email'
      AND ( -- roles here
        p.permission = 'ADMIN'
      )
    )
  )
);
