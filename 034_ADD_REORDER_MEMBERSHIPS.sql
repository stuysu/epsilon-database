-- Lets admins reorder every member of their organization, including other
-- admins (stuysu/epsilon#218). The membership update policies don't let admins
-- touch other admins' rows, so this only sets ordering_id and nothing else.
-- membership_ids is the new order: the first id gets ordering_id 0, and so on.
CREATE OR REPLACE FUNCTION public.reorder_memberships(org_id INT, membership_ids INT[])
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

GRANT EXECUTE ON FUNCTION public.reorder_memberships TO authenticated;
REVOKE EXECUTE ON FUNCTION public.reorder_memberships(INT, INT[]) FROM PUBLIC, anon;
