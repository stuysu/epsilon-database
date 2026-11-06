-- Security and correctness fixes, combined into one migration.
-- Safe to re-run. Already on prod: users admin policy and schedules lockdown.
-- The valentines section needs the matching frontend (epsilon#443).

-- ====================================================================
-- FIX_USERS_ADMIN_POLICY
-- ====================================================================
-- "Enable all access to site admins" on public.users checked is_admin(id),
-- i.e. whether the row being changed belongs to a site admin, not whether
-- the caller is one. Any signed-in user could therefore update or delete a
-- site admin's row (including changing its email to their own, which then
-- made them a site admin). Check the caller instead.
--
-- The lookup runs in a SECURITY DEFINER function so it can read users
-- without re-entering this table's RLS (which would recurse).

CREATE OR REPLACE FUNCTION public.caller_is_site_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users u
        JOIN public.permissions p ON p.user_id = u.id
        WHERE u.email = (auth.jwt() ->> 'email')
          AND p.permission = 'ADMIN'
    );
$$;

REVOKE ALL ON FUNCTION public.caller_is_site_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.caller_is_site_admin() TO authenticated;

DROP POLICY IF EXISTS "Enable all access to site admins" ON public.users;

CREATE POLICY "Enable all access to site admins"
ON public.users
FOR ALL
TO authenticated
USING (public.caller_is_site_admin())
WITH CHECK (public.caller_is_site_admin());

-- ====================================================================
-- FIX_MEMBERSHIP_ROLE_ESCALATION
-- ====================================================================
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

-- ====================================================================
-- ENFORCE_JOINABLE_ON_MEMBERSHIP_INSERT
-- ====================================================================
-- Makes the membership insert policy respect organizations.joinable and state.
-- The policy only checked that the organization existed, so anyone could insert
-- a join request straight through PostgREST for a club that turned joining off,
-- or for a PENDING or PUNISHED club. The join-organization function inserts with
-- the user's JWT, so this policy is what actually gates joining. LOCKED clubs stay
-- joinable on purpose: approved clubs start LOCKED and unlock once enough members
-- have been approved. Creator memberships (create-organization) and accepted
-- invites (accept-invite) are inserted with the service role and are not affected.
DROP POLICY IF EXISTS "Enable pending membership creation to authenticated users" ON public.memberships;

CREATE POLICY "Enable pending membership creation to authenticated users"
ON public.memberships
FOR INSERT
TO authenticated
WITH CHECK (
  (EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (
      (u.email = (auth.jwt() ->> 'email'))
      AND (user_id = u.id)
    )
  ))
  AND (EXISTS (
    SELECT 1
    FROM organizations AS o
    WHERE (
      (o.id = organization_id)
      AND (o.joinable IS TRUE)
      AND (o.state NOT IN ('PENDING', 'PUNISHED'))
    )
  ))
  AND (active = false)
  AND (role = 'MEMBER')
  AND (role_name IS NULL)
);

-- ====================================================================
-- ALLOW_COLEADS_EDIT_PENDING_ORG
-- ====================================================================
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

-- ====================================================================
-- GET_BOOKED_ROOMS_TIMESTAMPTZ
-- ====================================================================
-- get_booked_rooms took `timestamp without time zone` arguments. Postgres
-- drops any UTC offset when parsing into that type, then converts back using
-- the session TimeZone when comparing against meetings.start_time/end_time
-- (both timestamptz). So '2026-11-10T21:30:00-05:00' was treated as 21:30 UTC,
-- and the 'Z' strings the frontend sends were only correct while the session
-- TimeZone was UTC.
--
-- Take timestamptz instead so the offset is kept and the session TimeZone no
-- longer matters for offset-bearing input. Results for the current callers
-- (ISO 'Z' strings over PostgREST, whose session is UTC) are unchanged.
-- The old overload is dropped so PostgREST cannot pick between two functions.
-- Return shape, body, security and grants are the same as before.

BEGIN;

DROP FUNCTION IF EXISTS public.get_booked_rooms(timestamp without time zone, timestamp without time zone);

CREATE OR REPLACE FUNCTION public.get_booked_rooms(meeting_start timestamptz, meeting_end timestamptz)
RETURNS TABLE (room_id INT, meeting_id INT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT r.id, m.id
  FROM rooms AS r
  INNER JOIN meetings AS m ON (m.room_id = r.id)
  WHERE (
    (
      meeting_start >= start_time and
      meeting_start <= end_time
    ) or
    (
      meeting_end >= start_time and
      meeting_end <= end_time
    ) or
    (
      start_time >= meeting_start and
      start_time <= meeting_end
    ) or
    (
      end_time >= meeting_start and
      end_time <= meeting_end
    )
  )
$$;

-- same grants the old function had on prod (PUBLIC, anon, authenticated, service_role)
GRANT EXECUTE ON FUNCTION public.get_booked_rooms(timestamptz, timestamptz) TO PUBLIC, anon, authenticated, service_role;

COMMIT;

-- make PostgREST see the new signature right away
NOTIFY pgrst, 'reload schema';

-- ====================================================================
-- LOCK_DOWN_SCHEDULES
-- ====================================================================
-- The schedules table had row level security turned off, and the anon and
-- authenticated roles could insert, update, delete and truncate it. Anyone with
-- the public anon key could rewrite or wipe the bell schedules that the
-- fetch-schedule function serves.
--
-- Reads stay public, since fetch-schedule queries this table with the anon
-- key. Writes are left to service_role and postgres (the dashboard and SQL
-- editor). Safe to run more than once.
ALTER TABLE public.schedules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable read access to everyone" ON public.schedules;

CREATE POLICY "Enable read access to everyone"
ON public.schedules
FOR SELECT
TO anon, authenticated
USING (true);

REVOKE ALL ON public.schedules FROM anon, authenticated;
GRANT SELECT ON public.schedules TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ====================================================================
-- HIDE_ANONYMOUS_VALENTINE_SENDERS
-- ====================================================================
-- Recipients could read their valentines straight from the table, which let
-- them select the sender column (or embed the sender's user row) even when the
-- sender asked to stay anonymous, and also read messages that had not been
-- approved yet.
--
-- Recipients now lose direct access to the table and read their valentines
-- through get_received_valentines() instead. It only returns approved
-- messages, only after the valentines_deadline setting has passed, and only
-- includes the sender when show_sender is true.
--
-- Not changed: senders still read and delete their own messages, and ADMIN and
-- VALENTINES moderators still read and modify every message. Safe to run more
-- than once.
DROP POLICY IF EXISTS "Recipient can read their messages after the release time."
ON public.valentinesmessages;

-- TRUNCATE ignores row level security, so nobody outside the backend needs it.
REVOKE TRUNCATE ON public.valentinesmessages FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_received_valentines()
RETURNS TABLE (
  id INT,
  sender INT,
  receiver INT,
  show_sender BOOLEAN,
  message TEXT,
  background VARCHAR,
  verified_at TIMESTAMP
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    v.id,
    CASE WHEN v.show_sender THEN v.sender END,
    v.receiver,
    v.show_sender,
    v.message,
    v.background,
    v.verified_at
  FROM public.valentinesmessages AS v
  INNER JOIN public.users AS u ON (u.id = v.receiver)
  WHERE u.email = (auth.jwt() ->> 'email')
    AND v.verified_at IS NOT NULL
    AND v.verified_by IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.settings AS s
      WHERE s.name = 'valentines_deadline'
        AND to_timestamp(s.setting_value::double precision) < now()
    )
  ORDER BY v.verified_at, v.id;
$$;

REVOKE ALL ON FUNCTION public.get_received_valentines() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_received_valentines() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ====================================================================
-- ATTENDANCE_CHECKIN_WINDOW
-- ====================================================================
-- Active members could mark themselves present for any meeting at any time,
-- for example a day before it started. They also only had to match the
-- organization_id they sent, not the meeting's actual club, so a member of one
-- club could record attendance for another club's meeting.
--
-- Self check-in now requires that the meeting belongs to the member's club and
-- that it is between 15 minutes before start_time and end_time. Club admins and
-- creators ("Enable all access to organization admins") and site admins can
-- still mark attendance at any time. Safe to run more than once.
DROP POLICY IF EXISTS "Enable insert access to active members of organization"
ON public.attendance;

CREATE POLICY "Enable insert access to active members of organization"
ON public.attendance
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships AS m ON (u.id = m.user_id)
    INNER JOIN meetings AS mt ON (mt.organization_id = m.organization_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = public.attendance.user_id
      AND m.organization_id = public.attendance.organization_id
      AND m.active = true
      AND mt.id = public.attendance.meeting_id
      AND now() >= mt.start_time - interval '15 minutes'
      AND now() <= mt.end_time
    )
  )
);

-- TRUNCATE ignores row level security, so nobody outside the backend needs it.
REVOKE TRUNCATE ON public.attendance FROM anon, authenticated;

-- ====================================================================
-- REQUIRE_ACTIVE_ADMIN
-- ====================================================================
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

-- ====================================================================
-- ATTENDANCE_ADMIN_SAME_ORG_MEETING
-- ====================================================================
-- Club admins could write attendance rows that pair their own organization_id
-- with a meeting from another club. Require the meeting to belong to the same
-- organization. Apply after 056.

-- supersedes the attendance policy in the active-admin section above
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
  AND EXISTS (
    SELECT 1
    FROM meetings mt
    WHERE mt.id = attendance.meeting_id
      AND mt.organization_id = attendance.organization_id
  )
);
