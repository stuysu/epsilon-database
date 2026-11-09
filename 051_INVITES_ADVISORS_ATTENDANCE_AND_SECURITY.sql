-- Organization invites, faculty advisors and attendance details.
-- Invites are accepted through the accept-invite edge function.

BEGIN;

-- ====================================================================
-- INVITES
-- ====================================================================
CREATE TABLE IF NOT EXISTS organization_invites (
  id SERIAL PRIMARY KEY,
  organization_id INT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invited_by INT REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
  CONSTRAINT one_invite_per_user UNIQUE (organization_id, user_id)
);

ALTER TABLE organization_invites ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON organization_invites FROM anon, authenticated;
GRANT SELECT ON organization_invites TO authenticated;

DROP POLICY IF EXISTS "Enable organization admins and invited users to view invites" ON organization_invites;
CREATE POLICY "Enable organization admins and invited users to view invites"
  ON organization_invites FOR SELECT TO authenticated
  USING (
    organization_invites.user_id IN (
      SELECT users.id FROM users WHERE users.email = (auth.jwt() ->> 'email')
    )
    OR
    organization_invites.organization_id IN (
      SELECT public.get_user_admin_organizations()
      UNION
      SELECT public.get_user_creator_organizations()
    )
  );

INSERT INTO settings (name, setting_value, visible)
VALUES ('max_daily_invites', 10, false)
ON CONFLICT (name) DO NOTHING;

-- Returns one {email, status} per email: invited, already_invited,
-- already_member, no_account, invalid or limit_reached.
CREATE OR REPLACE FUNCTION public.create_organization_invites(org_id INT, emails TEXT[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  inviter_id INT;
  clean_email TEXT;
  invitee_id INT;
  results JSONB := '[]'::jsonb;
  status TEXT;
  daily_limit INT := coalesce(
    (SELECT setting_value FROM settings WHERE name = 'max_daily_invites'),
    10
  );
  sent_today INT := (
    SELECT count(*)
    FROM organization_invites
    WHERE (
      organization_invites.organization_id = org_id
      AND organization_invites.created_at > now() - INTERVAL '1 day'
    )
  );
BEGIN
  IF org_id NOT IN (
    SELECT public.get_user_admin_organizations()
    UNION
    SELECT public.get_user_creator_organizations()
  ) THEN
    RAISE EXCEPTION 'Only organization admins can invite members.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM organizations
    WHERE organizations.id = org_id AND organizations.state IN ('PENDING', 'PUNISHED')
  ) THEN
    RAISE EXCEPTION 'This Activity can''t invite members until it is approved and in good standing.';
  END IF;

  SELECT users.id INTO inviter_id FROM users WHERE users.email = (auth.jwt() ->> 'email');

  FOR clean_email IN
    SELECT lower(trim(email))
    FROM unnest(emails) WITH ORDINALITY AS entered (email, entered_order)
    WHERE trim(email) <> ''
    GROUP BY lower(trim(email))
    ORDER BY min(entered_order)
  LOOP
    invitee_id := NULL;
    IF clean_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
      status := 'invalid';
    ELSE
      SELECT users.id INTO invitee_id FROM users WHERE lower(users.email) = clean_email;

      IF invitee_id IS NULL THEN
        status := 'no_account';
      ELSIF EXISTS (
        SELECT 1 FROM memberships
        WHERE (
          memberships.organization_id = org_id
          AND memberships.user_id = invitee_id
          AND memberships.active = true
        )
      ) THEN
        status := 'already_member';
      ELSIF EXISTS (
        SELECT 1 FROM organization_invites
        WHERE (
          organization_invites.organization_id = org_id
          AND organization_invites.user_id = invitee_id
          AND organization_invites.status = 'pending'
        )
      ) THEN
        status := 'already_invited';
      ELSIF sent_today >= daily_limit THEN
        status := 'limit_reached';
      ELSE
        -- someone who declined or left can be invited again
        INSERT INTO organization_invites (organization_id, user_id, invited_by)
        VALUES (org_id, invitee_id, inviter_id)
        ON CONFLICT ON CONSTRAINT one_invite_per_user DO UPDATE
        SET status = 'pending', invited_by = inviter_id, created_at = now();
        sent_today := sent_today + 1;
        status := 'invited';
      END IF;
    END IF;

    results := results || jsonb_build_object('email', clean_email, 'status', status);
  END LOOP;

  RETURN results;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_organization_invites(INT, TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_organization_invites(INT, TEXT[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.decline_organization_invite(invite_id INT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE organization_invites
  SET status = 'declined'
  FROM users
  WHERE (
    organization_invites.id = invite_id
    AND organization_invites.status = 'pending'
    AND users.id = organization_invites.user_id
    AND users.email = (auth.jwt() ->> 'email')
  );
$$;

REVOKE EXECUTE ON FUNCTION public.decline_organization_invite(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decline_organization_invite(INT) TO authenticated;

-- Cancelled invites are kept, so they still count toward the daily limit.
CREATE OR REPLACE FUNCTION public.cancel_organization_invite(invite_id INT)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH cancelled AS (
    UPDATE organization_invites
    SET status = 'cancelled'
    WHERE (
      organization_invites.id = invite_id
      AND organization_invites.status = 'pending'
      AND organization_invites.organization_id IN (
        SELECT public.get_user_admin_organizations()
        UNION
        SELECT public.get_user_creator_organizations()
      )
    )
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM cancelled);
$$;

REVOKE EXECUTE ON FUNCTION public.cancel_organization_invite(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_organization_invite(INT) TO authenticated;

-- Someone who joins another way (e.g. an approved join request) no longer has
-- a pending invite.
CREATE OR REPLACE FUNCTION public.close_invites_on_join()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE organization_invites
  SET status = 'accepted'
  WHERE (
    organization_id = NEW.organization_id
    AND user_id = NEW.user_id
    AND status = 'pending'
  );
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.close_invites_on_join() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS close_invites_on_join ON memberships;
CREATE TRIGGER close_invites_on_join
  AFTER INSERT OR UPDATE OF active ON memberships
  FOR EACH ROW WHEN (NEW.active)
  EXECUTE FUNCTION public.close_invites_on_join();

-- ====================================================================
-- ADVISORS
-- ====================================================================
-- Advisors stay memberships with the ADVISOR role, but only faculty accounts
-- can be given it. Rows that already have it are left alone.
CREATE OR REPLACE FUNCTION public.enforce_faculty_advisor()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.role = 'ADVISOR'
    AND (TG_OP = 'INSERT' OR OLD.role IS DISTINCT FROM 'ADVISOR' OR OLD.user_id <> NEW.user_id)
    AND NOT EXISTS (SELECT 1 FROM users WHERE users.id = NEW.user_id AND users.is_faculty)
  THEN
    RAISE EXCEPTION 'Only faculty can be advisors.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_faculty_advisor ON memberships;
CREATE TRIGGER enforce_faculty_advisor
  BEFORE INSERT OR UPDATE OF role, user_id ON memberships
  FOR EACH ROW EXECUTE FUNCTION public.enforce_faculty_advisor();

-- Returns added, already_advisor, already_leader, no_account or not_faculty.
-- Not callable by clients; see add_organization_advisor and add_charter_advisor.
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

  IF existing_role IN ('ADMIN', 'CREATOR') THEN
    RETURN 'already_leader';
  END IF;

  INSERT INTO memberships (organization_id, user_id, role, active)
  VALUES (org_id, advisor_id, 'ADVISOR', true)
  ON CONFLICT ON CONSTRAINT no_duplicate_joins DO UPDATE
  SET role = 'ADVISOR', role_name = NULL, active = true;

  RETURN 'added';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.make_organization_advisor(INT, TEXT) FROM PUBLIC, anon, authenticated;

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

REVOKE EXECUTE ON FUNCTION public.add_organization_advisor(INT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_organization_advisor(INT, TEXT) TO authenticated;

-- Called by the approve-organization and approve-organization-edit functions.
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

SELECT public.add_charter_advisor(organizations.id)
FROM organizations
WHERE organizations.state <> 'PENDING';

-- ====================================================================
-- ATTENDANCE DETAILS
-- ====================================================================
ALTER TABLE attendance ADD COLUMN IF NOT EXISTS late BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE attendance ADD COLUMN IF NOT EXISTS left_early BOOLEAN NOT NULL DEFAULT false;

-- 048 limits attendance writes to a few columns. Admins can now also set the
-- marks; the trigger below decides them for self check-ins, and members have
-- no update policy.
GRANT INSERT (late, left_early) ON public.attendance TO authenticated;
GRANT UPDATE (late, left_early) ON public.attendance TO authenticated;

ALTER TABLE organizations ADD COLUMN IF NOT EXISTS late_after_minutes INT NOT NULL DEFAULT 15;
ALTER TABLE organizations DROP CONSTRAINT IF EXISTS late_after_minutes_range;
ALTER TABLE organizations ADD CONSTRAINT late_after_minutes_range
  CHECK (late_after_minutes BETWEEN 0 AND 240);

-- Members checking themselves in can't choose their own marks: late is worked
-- out from the club's rule, and left_early is always false.
CREATE OR REPLACE FUNCTION public.attendance_self_checkin_marks()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  caller_id INT;
BEGIN
  SELECT u.id INTO caller_id
  FROM public.users u
  WHERE u.email = (auth.jwt() ->> 'email');

  IF caller_id IS NULL OR caller_id <> NEW.user_id THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.user_id = caller_id
      AND m.organization_id = NEW.organization_id
      AND m.role IN ('ADMIN', 'CREATOR', 'ADVISOR')
      AND m.active
  ) OR EXISTS (
    SELECT 1 FROM public.permissions p
    WHERE p.user_id = caller_id AND p.permission = 'ADMIN'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT now() > mt.start_time + make_interval(mins => o.late_after_minutes)
  INTO NEW.late
  FROM public.meetings mt
  JOIN public.organizations o ON o.id = mt.organization_id
  WHERE mt.id = NEW.meeting_id;

  NEW.late := COALESCE(NEW.late, false);
  NEW.left_early := false;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS attendance_self_checkin_marks ON attendance;
CREATE TRIGGER attendance_self_checkin_marks
  BEFORE INSERT ON attendance
  FOR EACH ROW EXECUTE FUNCTION public.attendance_self_checkin_marks();

-- Same pattern as set_organization_joinable: admins can't update approved
-- clubs directly, so this only touches the lateness rule.
CREATE OR REPLACE FUNCTION public.set_organization_late_after(org_id INT, minutes INT)
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
    WHERE memberships.organization_id = org_id
      AND users.email = (auth.jwt() ->> 'email')
      AND memberships.role IN ('ADMIN', 'CREATOR', 'ADVISOR')
      AND memberships.active
  ) AND NOT EXISTS (
    SELECT 1
    FROM permissions
    INNER JOIN users ON (permissions.user_id = users.id)
    WHERE users.email = (auth.jwt() ->> 'email')
      AND permissions.permission = 'ADMIN'
  ) THEN
    RAISE EXCEPTION 'Only organization admins can change the lateness rule.';
  END IF;

  UPDATE organizations
  SET late_after_minutes = minutes
  WHERE id = org_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_organization_late_after(INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_organization_late_after(INT, INT) TO authenticated;

-- ====================================================================
-- ADVISOR LEADER TOOLS
-- ====================================================================
-- Attendance, meetings, roster and posts. Messages and charter edits stay
-- with student leaders.
CREATE OR REPLACE FUNCTION public.get_user_admin_organizations()
 RETURNS SETOF integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT organization_id
  FROM memberships
  INNER JOIN users ON (memberships.user_id = users.id)
  WHERE (
    (users.email = auth.jwt() ->> 'email')
    AND (memberships.role IN ('ADMIN', 'ADVISOR'))
    AND memberships.active
  )
$function$;

CREATE OR REPLACE FUNCTION public.reorder_memberships(org_id integer, membership_ids integer[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM memberships
    INNER JOIN users ON (memberships.user_id = users.id)
    WHERE (
      memberships.organization_id = org_id
      AND users.email = (auth.jwt() ->> 'email')
      AND memberships.role IN ('ADMIN', 'CREATOR', 'ADVISOR')
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
$function$;

CREATE OR REPLACE FUNCTION public.set_membership_role_name(membership_id integer, new_role_name character varying)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      AND memberships.role IN ('ADMIN', 'CREATOR', 'ADVISOR')
      AND memberships.active
    )
  ) THEN
    RAISE EXCEPTION 'Only organization admins can change role names.';
  END IF;

  UPDATE memberships
  SET role_name = new_role_name
  WHERE id = membership_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_organization_joinable(org_id integer, new_joinable boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM memberships
    INNER JOIN users ON (memberships.user_id = users.id)
    WHERE (
      memberships.organization_id = org_id
      AND users.email = (auth.jwt() ->> 'email')
      AND memberships.role IN ('ADMIN', 'CREATOR', 'ADVISOR')
      AND memberships.active
    )
  ) THEN
    RAISE EXCEPTION 'Only organization admins can change whether the organization is joinable.';
  END IF;

  UPDATE organizations
  SET joinable = new_joinable
  WHERE id = org_id;
END;
$function$;

DROP POLICY IF EXISTS "Enable delete access to admins of organization" ON meetings;
CREATE POLICY "Enable delete access to admins of organization" ON meetings
  AS PERMISSIVE FOR DELETE TO authenticated
  USING ((EXISTS ( SELECT 1
   FROM (users u
     JOIN memberships m ON ((u.id = m.user_id)))
  WHERE ((u.email = (jwt() ->> 'email'::text)) AND (m.organization_id = meetings.organization_id) AND (m.role = ANY (ARRAY['ADMIN'::org_role, 'CREATOR'::org_role, 'ADVISOR'::org_role])) AND m.active))));

DROP POLICY IF EXISTS "Enable all access to organization admins" ON attendance;
CREATE POLICY "Enable all access to organization admins" ON attendance
  AS PERMISSIVE FOR ALL TO authenticated
  USING ((EXISTS ( SELECT 1
   FROM (users u
     JOIN memberships m ON ((u.id = m.user_id)))
  WHERE ((u.email = (jwt() ->> 'email'::text)) AND (m.organization_id = attendance.organization_id) AND (m.role = ANY (ARRAY['ADMIN'::org_role, 'CREATOR'::org_role, 'ADVISOR'::org_role])) AND m.active))))
  WITH CHECK (((EXISTS ( SELECT 1
   FROM (users u
     JOIN memberships m ON ((u.id = m.user_id)))
  WHERE ((u.email = (jwt() ->> 'email'::text)) AND (m.organization_id = attendance.organization_id) AND (m.role = ANY (ARRAY['ADMIN'::org_role, 'CREATOR'::org_role, 'ADVISOR'::org_role])) AND m.active))) AND (EXISTS ( SELECT 1
   FROM meetings mt
  WHERE ((mt.id = attendance.meeting_id) AND (mt.organization_id = attendance.organization_id)))) AND (EXISTS ( SELECT 1
   FROM memberships target
  WHERE ((target.user_id = attendance.user_id) AND (target.organization_id = attendance.organization_id) AND target.active)))));

-- club leaders create and edit meetings only through the create-meeting and
-- edit-meeting functions, which check rooms, times and advisors first
DROP POLICY IF EXISTS "Enable update access to admins of organization" ON meetings;
DROP POLICY IF EXISTS "Enable insert access to admins of organization" ON meetings;

DROP POLICY IF EXISTS "Enable all access to organization admins only" ON posts;
CREATE POLICY "Enable all access to organization admins only" ON posts
  AS PERMISSIVE FOR ALL TO authenticated
  USING ((EXISTS ( SELECT 1
   FROM (users u
     JOIN memberships m ON ((m.user_id = u.id)))
  WHERE ((u.email = (jwt() ->> 'email'::text)) AND (m.role = ANY (ARRAY['ADMIN'::org_role, 'CREATOR'::org_role, 'ADVISOR'::org_role])) AND m.active AND (m.organization_id = posts.organization_id)))))
  WITH CHECK ((EXISTS ( SELECT 1
   FROM (users u
     JOIN memberships m ON ((m.user_id = u.id)))
  WHERE ((u.email = (jwt() ->> 'email'::text)) AND (m.role = ANY (ARRAY['ADMIN'::org_role, 'CREATOR'::org_role, 'ADVISOR'::org_role])) AND m.active AND (m.organization_id = posts.organization_id)))));

-- ====================================================================
-- CHARTER ADVISOR ON SIGNUP
-- ====================================================================
-- Adds a charter's faculty advisor once their faculty account exists.
CREATE OR REPLACE FUNCTION public.add_charter_advisor_for_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT NEW.is_faculty THEN
    RETURN NEW;
  END IF;

  PERFORM make_organization_advisor(organizations.id, NEW.email)
  FROM organizations
  WHERE organizations.state <> 'PENDING'
    AND lower(trim(organizations.faculty_email)) = lower(trim(NEW.email));

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.add_charter_advisor_for_user() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS add_charter_advisor_for_new_user ON users;
CREATE TRIGGER add_charter_advisor_for_new_user
  AFTER INSERT ON users
  FOR EACH ROW
  WHEN (NEW.is_faculty)
  EXECUTE FUNCTION public.add_charter_advisor_for_user();

-- Only real changes, so an advisor the club removed isn't re-added on any save.
DROP TRIGGER IF EXISTS add_charter_advisor_for_updated_user ON users;
CREATE TRIGGER add_charter_advisor_for_updated_user
  AFTER UPDATE OF is_faculty, email ON users
  FOR EACH ROW
  WHEN (
    NEW.is_faculty
    AND (OLD.is_faculty IS DISTINCT FROM NEW.is_faculty
      OR OLD.email IS DISTINCT FROM NEW.email)
  )
  EXECUTE FUNCTION public.add_charter_advisor_for_user();

-- ====================================================================
-- CHECK-IN CODES
-- ====================================================================
-- Self check-in needs the code from the meeting's QR code or link, so members
-- can't mark themselves present without being there.

CREATE TABLE IF NOT EXISTS public.meeting_checkin_codes (
  meeting_id INT PRIMARY KEY REFERENCES public.meetings(id) ON DELETE CASCADE,
  code TEXT NOT NULL DEFAULT substr(replace(gen_random_uuid()::text, '-', ''), 1, 16),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- only reachable through the functions below
ALTER TABLE public.meeting_checkin_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.meeting_checkin_codes FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.meeting_checkin_code(p_meeting_id INT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  caller_id INT;
  org_id INT;
  result TEXT;
BEGIN
  SELECT u.id INTO caller_id FROM public.users u
  WHERE u.email = (auth.jwt() ->> 'email');

  SELECT mt.organization_id INTO org_id FROM public.meetings mt
  WHERE mt.id = p_meeting_id;

  IF caller_id IS NULL OR org_id IS NULL OR NOT (
    EXISTS (
      SELECT 1 FROM public.memberships m
      WHERE m.user_id = caller_id
        AND m.organization_id = org_id
        AND m.role IN ('ADMIN', 'CREATOR', 'ADVISOR')
        AND m.active
    ) OR EXISTS (
      SELECT 1 FROM public.permissions p
      WHERE p.user_id = caller_id AND p.permission = 'ADMIN'
    )
  ) THEN
    RAISE EXCEPTION 'Not allowed' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.meeting_checkin_codes (meeting_id)
  VALUES (p_meeting_id)
  ON CONFLICT (meeting_id) DO NOTHING;

  SELECT c.code INTO result FROM public.meeting_checkin_codes c
  WHERE c.meeting_id = p_meeting_id;
  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_in_to_meeting(p_meeting_id INT, p_code TEXT)
RETURNS public.attendance
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  caller_id INT;
  mt public.meetings%ROWTYPE;
  rec public.attendance%ROWTYPE;
BEGIN
  SELECT u.id INTO caller_id FROM public.users u
  WHERE u.email = (auth.jwt() ->> 'email');

  SELECT * INTO mt FROM public.meetings WHERE id = p_meeting_id;

  IF caller_id IS NULL OR mt.id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.user_id = caller_id
      AND m.organization_id = mt.organization_id
      AND m.active
  ) THEN
    RAISE EXCEPTION 'Not a member' USING ERRCODE = '42501';
  END IF;

  IF p_code IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.meeting_checkin_codes c
    WHERE c.meeting_id = p_meeting_id AND c.code = p_code
  ) THEN
    RAISE EXCEPTION 'Invalid check-in code' USING ERRCODE = '22023';
  END IF;

  IF now() < mt.start_time - public.attendance_checkin_opens_before()
     OR now() > mt.end_time + public.attendance_checkin_closes_after() THEN
    RAISE EXCEPTION 'Check-in is closed' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO rec FROM public.attendance a
  WHERE a.meeting_id = p_meeting_id AND a.user_id = caller_id;
  IF rec.id IS NOT NULL THEN
    RETURN rec;
  END IF;

  INSERT INTO public.attendance (organization_id, meeting_id, user_id, source, late)
  SELECT mt.organization_id, p_meeting_id, caller_id, 'SELF',
    now() > mt.start_time + make_interval(mins => o.late_after_minutes)
  FROM public.organizations o WHERE o.id = mt.organization_id
  RETURNING * INTO rec;
  RETURN rec;
END;
$$;

REVOKE ALL ON FUNCTION public.meeting_checkin_code(INT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.check_in_to_meeting(INT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.meeting_checkin_code(INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_in_to_meeting(INT, TEXT) TO authenticated;

-- members now go through check_in_to_meeting; admins keep their own policy
DROP POLICY IF EXISTS "Enable insert access to active members of organization" ON public.attendance;

-- ====================================================================
-- LINK ORDER
-- ====================================================================
-- Lets club admins reorder their approved links without an approval request.
-- new_order lists the current positions (1-based) in the new order, so links themselves can't change.
CREATE OR REPLACE FUNCTION public.reorder_organization_socials(org_id INT, new_order INT[])
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  old_text TEXT;
  is_json BOOLEAN;
  links TEXT[];
  result TEXT;
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
    RAISE EXCEPTION 'Only organization admins can reorder links.';
  END IF;

  SELECT btrim(coalesce(socials, '')) INTO old_text FROM organizations WHERE id = org_id;
  is_json := left(old_text, 1) = '[';

  -- older clubs store links separated by spaces
  IF is_json THEN
    SELECT coalesce(array_agg(e::TEXT ORDER BY i), '{}') INTO links
    FROM jsonb_array_elements(old_text::JSONB) WITH ORDINALITY AS t(e, i);
  ELSE
    SELECT coalesce(array_agg(u), '{}') INTO links
    FROM regexp_split_to_table(old_text, '\s+') u WHERE u <> '';
  END IF;

  IF coalesce(array_length(new_order, 1), 0) <> coalesce(array_length(links, 1), 0)
     OR (SELECT array_agg(p ORDER BY p) FROM unnest(new_order) p)
        IS DISTINCT FROM
        (SELECT array_agg(p) FROM generate_series(1, coalesce(array_length(links, 1), 0)) p) THEN
    RAISE EXCEPTION 'The new order must list every link once.';
  END IF;

  IF is_json THEN
    SELECT '[' || string_agg(links[p], ',' ORDER BY i) || ']' INTO result
    FROM unnest(new_order) WITH ORDINALITY AS t(p, i);
    result := result::JSONB::TEXT;
  ELSE
    SELECT string_agg(links[p], ' ' ORDER BY i) INTO result
    FROM unnest(new_order) WITH ORDINALITY AS t(p, i);
  END IF;

  UPDATE organizations SET socials = result WHERE id = org_id;
  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reorder_organization_socials TO authenticated;
REVOKE EXECUTE ON FUNCTION public.reorder_organization_socials(INT, INT[]) FROM PUBLIC, anon;

-- ====================================================================
-- CATALOG SORT FIELDS
-- ====================================================================
-- Fields the catalog can sort by, as PostgREST computed columns (?order=member_count.desc).
-- Counts the same members the catalog cards show: active, not advisors.
CREATE OR REPLACE FUNCTION public.member_count(org public.organizations)
RETURNS INT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::INT
  FROM memberships
  WHERE organization_id = org.id AND active AND role <> 'ADVISOR';
$$;

-- names sort by their first letter or number, so a leading space or symbol doesn't jump a club to the top
CREATE OR REPLACE FUNCTION public.sort_name(org public.organizations)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT lower(regexp_replace(org.name, '^[^[:alnum:]]+', ''));
$$;

-- shuffles searches too; changes daily, and stays fixed within a day so paging never repeats a club
CREATE OR REPLACE FUNCTION public.shuffle_rank(org public.organizations)
RETURNS TEXT
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT md5(org.id::TEXT || current_date::TEXT);
$$;

REVOKE EXECUTE ON FUNCTION public.member_count(public.organizations) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.member_count(public.organizations) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shuffle_rank(public.organizations) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sort_name(public.organizations) TO anon, authenticated;

-- ====================================================================
-- TRIMMED CLUB NAMES
-- ====================================================================
-- Charters are trimmed when saved now; this cleans names saved before that.
-- A name whose trimmed form is already taken is left alone.
UPDATE organizations o
SET name = btrim(o.name)
WHERE o.name <> btrim(o.name)
  AND NOT EXISTS (
    SELECT 1 FROM organizations other
    WHERE other.id <> o.id AND other.name = btrim(o.name)
  );

-- ====================================================================
-- AUDIT SECURITY FIXES
-- ====================================================================
-- Pending and past memberships (and their join messages) are visible only to
-- the member, the club's leaders and advisors, and site admins.
ALTER POLICY "Enable read access to authenticated users only" ON public.memberships
USING (
  EXISTS (
    SELECT 1 FROM users u WHERE u.email = auth.jwt() ->> 'email'
  )
  AND (
    active
    OR EXISTS (
      SELECT 1
      FROM users u
      WHERE u.email = auth.jwt() ->> 'email' AND u.id = memberships.user_id
    )
    OR organization_id IN (SELECT get_user_admin_organizations())
    OR organization_id IN (SELECT get_user_creator_organizations())
    OR caller_is_site_admin()
  )
);

-- messages are always written as the signed-in leader, and only they can change or delete them
ALTER POLICY "Enable insert for org admin own message" ON public.orgmessages
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND u.id = orgmessages.user_id
      AND m.organization_id = orgmessages.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

ALTER POLICY "Enable update for org admin own message" ON public.orgmessages
USING (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND u.id = orgmessages.user_id
      AND m.organization_id = orgmessages.organization_id
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
      AND u.id = orgmessages.user_id
      AND m.organization_id = orgmessages.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

ALTER POLICY "Enable delete for org admin own message" ON public.orgmessages
USING (
  EXISTS (
    SELECT 1
    FROM users u
    JOIN memberships m ON u.id = m.user_id
    WHERE u.email = auth.jwt() ->> 'email'
      AND u.id = orgmessages.user_id
      AND m.organization_id = orgmessages.organization_id
      AND m.role IN ('ADMIN', 'CREATOR')
      AND m.active
  )
);

-- even site admins post and edit only as themselves; they can still delete any message
DROP POLICY IF EXISTS "Messages are written as the signed-in user" ON public.orgmessages;
CREATE POLICY "Messages are written as the signed-in user" ON public.orgmessages
AS RESTRICTIVE
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = (SELECT u.id FROM users u WHERE u.email = auth.jwt() ->> 'email')
);

DROP POLICY IF EXISTS "Messages are edited only by their author" ON public.orgmessages;
CREATE POLICY "Messages are edited only by their author" ON public.orgmessages
AS RESTRICTIVE
FOR UPDATE
TO authenticated
USING (
  user_id = (SELECT u.id FROM users u WHERE u.email = auth.jwt() ->> 'email')
)
WITH CHECK (
  user_id = (SELECT u.id FROM users u WHERE u.email = auth.jwt() ->> 'email')
);

-- two requests at once can both pass the edge functions' room check, so the
-- database makes the final call; bookings that only touch count as a clash,
-- matching get_booked_rooms
CREATE OR REPLACE FUNCTION public.prevent_room_double_booking()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.room_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND NEW.room_id IS NOT DISTINCT FROM OLD.room_id
     AND NEW.start_time = OLD.start_time
     AND NEW.end_time = OLD.end_time THEN
    RETURN NEW;
  END IF;

  -- waits for any other booking of this room to commit first
  PERFORM pg_advisory_xact_lock(hashtext('room-booking'), NEW.room_id);

  IF EXISTS (
    SELECT 1
    FROM meetings m
    WHERE m.room_id = NEW.room_id
      AND m.id <> NEW.id
      AND m.start_time <= NEW.end_time
      AND m.end_time >= NEW.start_time
  ) THEN
    RAISE EXCEPTION 'This room is already booked at that time.'
      USING ERRCODE = '23P01';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_room_double_booking ON public.meetings;
CREATE TRIGGER prevent_room_double_booking
BEFORE INSERT OR UPDATE OF room_id, start_time, end_time ON public.meetings
FOR EACH ROW EXECUTE FUNCTION public.prevent_room_double_booking();

REVOKE EXECUTE ON FUNCTION public.prevent_room_double_booking() FROM PUBLIC, anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
