-- An ADMIN membership can be inactive (e.g. a pending or demoted leader whose
-- membership was never approved). Until now every organization-admin check
-- only looked at the role, so an inactive ADMIN still had full admin access.
-- Require the membership to be active everywhere an org admin is checked.
-- The CREATOR membership is always active, so this does not affect creators.

BEGIN;

-- Functions --------------------------------------------------------------

-- supersedes 005_CREATE_MEMBERSHIP_TABLE.sql
CREATE OR REPLACE FUNCTION public.get_user_admin_organizations()
RETURNS SETOF INT
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT organization_id
  FROM memberships
  INNER JOIN users ON (memberships.user_id = users.id)
  WHERE (
    (users.email = auth.jwt() ->> 'email')
    AND (memberships.role = 'ADMIN')
    AND memberships.active
  )
$$;

-- supersedes 034_ADD_REORDER_MEMBERSHIPS.sql
CREATE OR REPLACE FUNCTION public.reorder_memberships(org_id INT, membership_ids INT[])
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM memberships
    INNER JOIN users ON (memberships.user_id = users.id)
    WHERE (
      memberships.organization_id = org_id
      AND users.email = (auth.jwt() ->> 'email')
      AND memberships.role IN ('ADMIN', 'CREATOR')
      AND memberships.active
    )
  ) THEN
    RAISE EXCEPTION 'Only organization admins can reorder members.';
  END IF;

  UPDATE memberships
  SET ordering_id = new_order.position - 1
  FROM unnest(membership_ids) WITH ORDINALITY AS new_order(id, position)
  WHERE (
    memberships.id = new_order.id
    AND memberships.organization_id = org_id
  );
END;
$$;

-- supersedes 035_ADD_SET_MEMBERSHIP_ROLE_NAME.sql
CREATE OR REPLACE FUNCTION public.set_membership_role_name(membership_id INT, new_role_name VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  target_org INT;
  target_role org_role;
BEGIN
  SELECT organization_id, role INTO target_org, target_role
  FROM memberships
  WHERE id = membership_id;

  IF target_org IS NULL THEN
    RAISE EXCEPTION 'Membership does not exist.';
  END IF;

  IF target_role = 'CREATOR' THEN
    RAISE EXCEPTION 'Only the creator can change their own role name.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM memberships
    INNER JOIN users ON (memberships.user_id = users.id)
    WHERE (
      memberships.organization_id = target_org
      AND users.email = (auth.jwt() ->> 'email')
      AND memberships.role IN ('ADMIN', 'CREATOR')
      AND memberships.active
    )
  ) THEN
    RAISE EXCEPTION 'Only organization admins can change role names.';
  END IF;

  UPDATE memberships
  SET role_name = new_role_name
  WHERE id = membership_id;
END;
$$;

-- supersedes 036_ADD_SET_ORGANIZATION_JOINABLE.sql
CREATE OR REPLACE FUNCTION public.set_organization_joinable(org_id INT, new_joinable BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM memberships
    INNER JOIN users ON (memberships.user_id = users.id)
    WHERE (
      memberships.organization_id = org_id
      AND users.email = (auth.jwt() ->> 'email')
      AND memberships.role IN ('ADMIN', 'CREATOR')
      AND memberships.active
    )
  ) THEN
    RAISE EXCEPTION 'Only organization admins can change whether the organization is joinable.';
  END IF;

  UPDATE organizations
  SET joinable = new_joinable
  WHERE id = org_id;
END;
$$;

-- Policies ---------------------------------------------------------------

-- supersedes 020_CREATE_ATTENDANCE_TABLE.sql
ALTER POLICY "Enable all access to organization admins" ON public.attendance
USING (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.organization_id = attendance.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.organization_id = attendance.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 006_CREATE_MEETINGS_TABLE.sql
ALTER POLICY "Enable delete access to admins of organization" ON public.meetings
USING (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.organization_id = meetings.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 006_CREATE_MEETINGS_TABLE.sql
ALTER POLICY "Enable insert access to admins of organization" ON public.meetings
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.organization_id = meetings.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 039_RESTRICT_PAST_MEETING_EDITS.sql
ALTER POLICY "Enable update access to admins of organization" ON public.meetings
USING (
  end_time > now()
  AND EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.organization_id = meetings.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
)
WITH CHECK (
  end_time > now()
  AND EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.organization_id = meetings.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 009_CREATE_ORG_EDITS_TABLE.sql
ALTER POLICY "Allow organization admins all access to their organizationedits" ON public.organizationedits
USING (
  EXISTS (
    SELECT 1
    FROM memberships m
    JOIN users u ON m.user_id = u.id
    WHERE u.email = auth.jwt() ->> 'email'
      AND organizationedits.organization_id = m.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM memberships m
    JOIN users u ON m.user_id = u.id
    WHERE u.email = auth.jwt() ->> 'email'
      AND organizationedits.organization_id = m.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 012_CREATE_ORG_MESSAGES.sql
ALTER POLICY "Enable read for org admins" ON public.orgmessages
USING (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.organization_id = orgmessages.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 012_CREATE_ORG_MESSAGES.sql
ALTER POLICY "Enable insert for org admin own message" ON public.orgmessages
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND u.id = m.user_id
      AND m.organization_id = orgmessages.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 012_CREATE_ORG_MESSAGES.sql
ALTER POLICY "Enable update for org admin own message" ON public.orgmessages
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND u.id = m.user_id
      AND m.organization_id = orgmessages.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 012_CREATE_ORG_MESSAGES.sql
ALTER POLICY "Enable delete for org admin own message" ON public.orgmessages
USING (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND u.id = m.user_id
      AND m.organization_id = orgmessages.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- supersedes 008_CREATE_POSTS_TABLE.sql
ALTER POLICY "Enable all access to organization admins only" ON public.posts
USING (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON m.user_id = u.id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
      AND m.organization_id = posts.organization_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON m.user_id = u.id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
      AND m.organization_id = posts.organization_id
  )
);

-- supersedes 010_CREATE_STRIKES_TABLE.sql
ALTER POLICY "Enable read access to admins of organization" ON public.strikes
USING (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND m.organization_id = strikes.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

COMMIT;
