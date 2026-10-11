-- Lets admins change the role name of other admins. The membership update
-- policies don't let admins edit other admins' rows, so this only sets
-- role_name and nothing else (role, active, etc. are left alone).
-- The creator's role name can still only be changed by the creator.
CREATE OR REPLACE FUNCTION public.set_membership_role_name(membership_id INT, new_role_name VARCHAR(255))
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
    )
  ) THEN
    RAISE EXCEPTION 'Only organization admins can change role names.';
  END IF;

  UPDATE memberships
  SET role_name = new_role_name
  WHERE id = membership_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_membership_role_name TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_membership_role_name(INT, VARCHAR) FROM PUBLIC, anon;
