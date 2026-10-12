-- Lets organization admins and creators turn their club joinable on and off.
-- The organizations update policies only allow the creator to update a club
-- while it is still PENDING (and site admins), so toggling joinable on an
-- approved club silently updated 0 rows. This only sets joinable and nothing
-- else, so clubs still can't edit their charter without going through approval.
CREATE OR REPLACE FUNCTION public.set_organization_joinable(org_id INT, new_joinable BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
    )
  ) THEN
    RAISE EXCEPTION 'Only organization admins can change whether the organization is joinable.';
  END IF;

  UPDATE organizations
  SET joinable = new_joinable
  WHERE id = org_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_organization_joinable TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_organization_joinable(INT, BOOLEAN) FROM PUBLIC, anon;
