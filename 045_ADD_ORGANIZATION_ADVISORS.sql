-- Advisors are kept apart from members: they are added by their faculty email
-- instead of joining, and they don't count toward member totals. An advisor is
-- still stored as a membership with the ADVISOR role, so existing advisors and
-- the meeting form's advisor list keep working. Admins remove an advisor the
-- same way they remove a member.

-- Makes a faculty user an advisor of an organization. Returns added,
-- already_advisor, already_leader, no_account or not_faculty. Not callable by
-- clients; see add_organization_advisor and add_charter_advisor.
CREATE OR REPLACE FUNCTION public.make_organization_advisor(org_id INT, advisor_email TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  advisor_id INT;
  advisor_is_faculty BOOLEAN;
  existing_role org_role;
BEGIN
  SELECT users.id, users.is_faculty
  INTO advisor_id, advisor_is_faculty
  FROM users
  WHERE lower(users.email) = lower(trim(advisor_email));

  IF advisor_id IS NULL THEN
    RETURN 'no_account';
  END IF;

  IF NOT coalesce(advisor_is_faculty, false) THEN
    RETURN 'not_faculty';
  END IF;

  SELECT memberships.role
  INTO existing_role
  FROM memberships
  WHERE (
    memberships.organization_id = org_id
    AND memberships.user_id = advisor_id
  );

  IF existing_role = 'ADVISOR' THEN
    RETURN 'already_advisor';
  END IF;

  -- a leader keeps their role, anyone else becomes the advisor
  IF existing_role IN ('ADMIN', 'CREATOR') THEN
    RETURN 'already_leader';
  END IF;

  INSERT INTO memberships (organization_id, user_id, role, active)
  VALUES (org_id, advisor_id, 'ADVISOR', true)
  ON CONFLICT ON CONSTRAINT no_duplicate_joins DO UPDATE
  SET role = 'ADVISOR', role_name = NULL, active = true;

  -- an advisor doesn't need a pending invite to join as a member
  DELETE FROM organization_invites
  WHERE (organization_id = org_id AND user_id = advisor_id AND status = 'pending');

  RETURN 'added';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.make_organization_advisor(INT, TEXT) FROM PUBLIC, anon, authenticated;

-- Lets an organization's admins add an advisor by email from the Personnel page.
CREATE OR REPLACE FUNCTION public.add_organization_advisor(org_id INT, advisor_email TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF org_id NOT IN (
    SELECT public.get_user_admin_organizations()
    UNION
    SELECT public.get_user_creator_organizations()
  ) THEN
    RAISE EXCEPTION 'Only organization admins can add advisors.';
  END IF;

  RETURN make_organization_advisor(org_id, advisor_email);
END;
$$;

GRANT EXECUTE ON FUNCTION public.add_organization_advisor TO authenticated;
REVOKE EXECUTE ON FUNCTION public.add_organization_advisor(INT, TEXT) FROM PUBLIC, anon;

-- Adds the faculty email from an organization's charter as its advisor. Called
-- by the approve-organization and approve-organization-edit edge functions.
-- An email that isn't a faculty account on Epsilon is skipped.
CREATE OR REPLACE FUNCTION public.add_charter_advisor(org_id INT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  charter_email TEXT := (SELECT faculty_email FROM organizations WHERE id = org_id);
BEGIN
  IF coalesce(trim(charter_email), '') = '' THEN
    RETURN 'no_email';
  END IF;

  RETURN make_organization_advisor(org_id, charter_email);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.add_charter_advisor(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.add_charter_advisor(INT) TO service_role;

-- Adds the charter advisor of every organization that is already approved.
SELECT public.add_charter_advisor(organizations.id)
FROM organizations
WHERE organizations.state <> 'PENDING';

NOTIFY pgrst, 'reload schema';
