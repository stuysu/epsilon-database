-- Fixes and features from the 2026-11-22 audit and the follow-up audits, in
-- one transaction: it applies completely or not at all. Safe to re-run.
-- 055 and 056 are taken by SU Applications and SU Votes.
-- Run the pre-checks in the prod steps first; a check below stops the whole
-- migration if prod data needs fixing by hand.

BEGIN;

-- ####################################################################
-- Part 1: migration tracking
-- ####################################################################
-- Records which migrations have run. scripts/apply-migration.sh checks and
-- fills this table. Rows for 001-054 are a backfill (applied_at unknown).
-- 055/056 live on other branches. This migration records itself below.

CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version text PRIMARY KEY,
  name text,
  applied_at timestamptz DEFAULT now(),
  applied_by text
);

-- service role only
ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.schema_migrations FROM PUBLIC, anon, authenticated;

INSERT INTO public.schema_migrations (version, name, applied_at, applied_by)
VALUES
  ('001', '001_CREATE_USER_TABLE.sql', NULL, 'backfill'),
  ('002', '002_CREATE_ORG_TABLE.sql', NULL, 'backfill'),
  ('003', '003_CREATE_PERMISSIONS_TABLE.sql', NULL, 'backfill'),
  ('004', '004_CREATE_ROOMS_TABLE.sql', NULL, 'backfill'),
  ('005', '005_CREATE_MEMBERSHIP_TABLE.sql', NULL, 'backfill'),
  ('006', '006_CREATE_MEETINGS_TABLE.sql', NULL, 'backfill'),
  ('007', '007_CREATE_ORG_POLICY.sql', NULL, 'backfill'),
  ('008', '008_CREATE_POSTS_TABLE.sql', NULL, 'backfill'),
  ('009', '009_CREATE_ORG_EDITS_TABLE.sql', NULL, 'backfill'),
  ('010', '010_CREATE_STRIKES_TABLE.sql', NULL, 'backfill'),
  ('011', '011_CREATE_SETTINGS_TABLE.sql', NULL, 'backfill'),
  ('012', '012_CREATE_ORG_MESSAGES.sql', NULL, 'backfill'),
  ('013', '013_DATABASE_FUNCS.sql', NULL, 'backfill'),
  ('014', '014_DATABASE_FUNC_PERMS.sql', NULL, 'backfill'),
  ('015', '015_STORAGE_PERMS.sql', NULL, 'backfill'),
  ('016', '016_CREATE_BACKGROUNDTOKENS.sql', NULL, 'backfill'),
  ('017', '017_CREATE_GOOGLECALENDARS.sql', NULL, 'backfill'),
  ('018', '018_CREATE_GOOGLECALENDAREVENTS.sql', NULL, 'backfill'),
  ('019', '019_CREATE_ANNOUNCEMENTS_TABLE.sql', NULL, 'backfill'),
  ('020', '020_CREATE_ATTENDANCE_TABLE.sql', NULL, 'backfill'),
  ('021', '021_FIX_PENDING_ORGANIZATION.sql', NULL, 'backfill'),
  ('022', '022_EDIT_ORG_COLUMNS.sql', NULL, 'backfill'),
  ('023', '023_ADD_DEFAULT_SETTING.sql', NULL, 'backfill'),
  ('024', '024_CREATE_FOURDIGITID_TABLE.sql', NULL, 'backfill'),
  ('025', '025_CREATE_SCHEDULE_TABLE.sql', NULL, 'backfill'),
  ('026', '026_DISPLAY_LOCKED_ORGS.sql', NULL, 'backfill'),
  ('027', '027_CREATE_NOTIFICATIONS.sql', NULL, 'backfill'),
  ('028', '028_CHARTER_REVISIONS.sql', NULL, 'backfill'),
  ('029', '029_CREATE_VALENTINES_TABLE.sql', NULL, 'backfill'),
  ('030', '030_ADD_USERS.sql', NULL, 'backfill'),
  ('031', '031_ADD_MEETINGS_ADVISOR.sql', NULL, 'backfill'),
  ('032', '032_FIX_PERMISSIONS_RLS.sql', NULL, 'backfill'),
  ('033', '033_ADD_MEMBERSHIP_ORDERING_ID.sql', NULL, 'backfill'),
  ('034', '034_ADD_REORDER_MEMBERSHIPS.sql', NULL, 'backfill'),
  ('035', '035_ADD_SET_MEMBERSHIP_ROLE_NAME.sql', NULL, 'backfill'),
  ('036', '036_ADD_SET_ORGANIZATION_JOINABLE.sql', NULL, 'backfill'),
  ('037', '037_FIX_MEETING_DAYS_TIMEZONE.sql', NULL, 'backfill'),
  ('038', '038_HIDE_EPSILON_MEETING_DAYS.sql', NULL, 'backfill'),
  ('039', '039_RESTRICT_PAST_MEETING_EDITS.sql', NULL, 'backfill'),
  ('040', '040_ADD_ROOM_GRANTS.sql', NULL, 'backfill'),
  ('041', '041_ALLOW_ANON_VIEW_LEADERS.sql', NULL, 'backfill'),
  ('042', '042_REVERT_ANON_VIEW_LEADERS.sql', NULL, 'backfill'),
  ('047', '047_ADD_ROOM_AIS_DAYS.sql', NULL, 'backfill'),
  ('048', '048_SECURITY_FIXES.sql', NULL, 'backfill'),
  ('049', '049_ORGANIZATION_SEARCH_TEXT.sql', NULL, 'backfill'),
  ('050', '050_CREATE_OPPORTUNITIES.sql', NULL, 'backfill'),
  ('051', '051_INVITES_ADVISORS_ATTENDANCE_AND_SECURITY.sql', NULL, 'backfill'),
  ('052', '052_OPPORTUNITY_BULLETIN_IMPORTER.sql', NULL, 'backfill'),
  ('054', '054_ROOM_BLOCKS.sql', NULL, 'backfill')
ON CONFLICT (version) DO NOTHING;

INSERT INTO public.schema_migrations (version, name, applied_by)
VALUES ('057', '057_AUDIT_FIXES.sql', current_user)
ON CONFLICT (version) DO NOTHING;


-- ####################################################################
-- Part 2: security and performance
-- ####################################################################
-- Security and performance fixes.

-- ====================================================================
-- Only Epsilon users can read users
-- ====================================================================
-- Any Google account gets a session, so "authenticated" alone let anyone
-- read every name and email. The lookup runs as definer so it doesn't
-- re-enter this table's RLS.

CREATE OR REPLACE FUNCTION public.caller_is_verified()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.users u
        WHERE u.email = (auth.jwt() ->> 'email')
    );
$$;

REVOKE ALL ON FUNCTION public.caller_is_verified() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.caller_is_verified() TO authenticated;

DROP POLICY IF EXISTS "Enable read access to authenticated users only" ON public.users;
CREATE POLICY "Enable read access to authenticated users only"
ON public.users
FOR SELECT
TO authenticated
USING ((SELECT public.caller_is_verified()));

-- 030's insert policy reads users from a users policy, which now recurses.
-- "Enable all access to site admins" already covers admin inserts.
DROP POLICY IF EXISTS "Allow insert for site admin" ON public.users;

-- ====================================================================
-- Policies look up the caller once per query
-- ====================================================================
-- Under the policy above, a users lookup in another policy can't use the
-- email index, and one that also mentions the row (is_public, a club id)
-- reran for every row: the calendar timed out. These helpers run as
-- definer; wrapped in (SELECT ...) they run once.

-- same as 055's and part 6's
CREATE OR REPLACE FUNCTION public.current_user_id()
RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.id FROM users AS u WHERE u.email = (auth.jwt() ->> 'email');
$$;

REVOKE ALL ON FUNCTION public.current_user_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_id() TO authenticated;

-- the caller's active clubs, or only those where they hold one of roles
CREATE OR REPLACE FUNCTION public.caller_organizations(roles public.org_role[] DEFAULT NULL)
RETURNS SETOF integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT m.organization_id FROM memberships m
    WHERE m.user_id = public.current_user_id()
      AND m.active
      AND (roles IS NULL OR m.role = ANY (roles));
$$;

REVOKE ALL ON FUNCTION public.caller_organizations(public.org_role[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.caller_organizations(public.org_role[]) TO authenticated;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['users', 'meetings', 'attendance', 'organizations', 'rooms',
        'room_grants', 'room_blocks', 'organizationedits', 'orgmessages', 'strikes',
        'announcements', 'settings'] LOOP
        EXECUTE format('ALTER POLICY "Enable all access to site admins" ON public.%I
            USING ((SELECT public.caller_is_site_admin()))
            WITH CHECK ((SELECT public.caller_is_site_admin()))', t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['rooms', 'room_grants', 'room_blocks'] LOOP
        EXECUTE format('ALTER POLICY "Enable read access to all authenticated users" ON public.%I
            USING ((SELECT public.caller_is_verified()))', t);
    END LOOP;
END $$;

ALTER POLICY "Enable read access of public meetings to authenticated users"
ON public.meetings
USING (is_public AND (SELECT public.caller_is_verified()));

ALTER POLICY "Enable read access of all organization meetings to active organization members"
ON public.meetings
USING (organization_id IN (SELECT public.caller_organizations()));

ALTER POLICY "Enable read access to authenticated users only"
ON public.memberships
USING (
    (SELECT public.caller_is_verified())
    AND (
        active
        OR user_id = (SELECT public.current_user_id())
        OR organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR,ADVISOR}'))
        OR (SELECT public.caller_is_site_admin())
    )
);

ALTER POLICY "Enable read access for own attendance"
ON public.attendance
USING (
    user_id = (SELECT public.current_user_id())
    AND EXISTS (SELECT 1 FROM memberships m WHERE m.user_id = (SELECT public.current_user_id()))
);

ALTER POLICY "Enable all access to organization admins"
ON public.attendance
USING (organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR,ADVISOR}')))
WITH CHECK (
    organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR,ADVISOR}'))
    AND EXISTS (
        SELECT 1 FROM meetings mt
        WHERE mt.id = attendance.meeting_id
          AND mt.organization_id = attendance.organization_id
    )
    AND EXISTS (
        SELECT 1 FROM memberships target
        WHERE target.user_id = attendance.user_id
          AND target.organization_id = attendance.organization_id
          AND target.active
    )
);

ALTER POLICY "Allow organization admins all access to their organizationedits"
ON public.organizationedits
USING (organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR}')))
WITH CHECK (organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR}')));

ALTER POLICY "Enable read for org admins"
ON public.orgmessages
USING (organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR}')));

ALTER POLICY "Enable read access to admins of organization"
ON public.strikes
USING (organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR}')));

ALTER POLICY "Enable read access to anyone with permissions"
ON public.permissions
USING (user_id = (SELECT public.current_user_id()));

-- ====================================================================
-- Club posts: members read, approved clubs write
-- ====================================================================
-- Any signed-in user could read every club's posts through the API. Now
-- only the club's active members (leaders and advisors too) and site admins
-- can. Clubs that aren't approved can't post or edit posts (site admins
-- can); they can still delete them.

DROP POLICY IF EXISTS "Enable read access to authenticated users only" ON public.posts;
DROP POLICY IF EXISTS "Enable read access to club members" ON public.posts;
CREATE POLICY "Enable read access to club members"
ON public.posts
FOR SELECT
TO authenticated
USING (
    organization_id IN (SELECT public.caller_organizations())
    OR (SELECT public.caller_is_site_admin())
);

DROP POLICY IF EXISTS "Enable all access to organization admins only" ON public.posts;
DROP POLICY IF EXISTS "Enable insert access to organization admins" ON public.posts;
DROP POLICY IF EXISTS "Enable update access to organization admins" ON public.posts;
DROP POLICY IF EXISTS "Enable delete access to organization admins" ON public.posts;

CREATE POLICY "Enable insert access to organization admins"
ON public.posts
FOR INSERT
TO authenticated
WITH CHECK (
    organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR,ADVISOR}'))
    AND (
        (SELECT public.caller_is_site_admin())
        OR EXISTS (
            SELECT 1 FROM organizations o
            WHERE o.id = posts.organization_id AND o.state IN ('UNLOCKED', 'ADMIN')
        )
    )
);

CREATE POLICY "Enable update access to organization admins"
ON public.posts
FOR UPDATE
TO authenticated
USING (organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR,ADVISOR}')))
WITH CHECK (
    organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR,ADVISOR}'))
    AND (
        (SELECT public.caller_is_site_admin())
        OR EXISTS (
            SELECT 1 FROM organizations o
            WHERE o.id = posts.organization_id AND o.state IN ('UNLOCKED', 'ADMIN')
        )
    )
);

CREATE POLICY "Enable delete access to organization admins"
ON public.posts
FOR DELETE
TO authenticated
USING (organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR,ADVISOR}')));

-- ====================================================================
-- Pending charters are only visible to Epsilon users
-- ====================================================================

DROP POLICY IF EXISTS "Enable read access to everyone" ON public.organizations;
DROP POLICY IF EXISTS "Enable read access to visitors" ON public.organizations;
DROP POLICY IF EXISTS "Enable read access to signed-in users" ON public.organizations;

CREATE POLICY "Enable read access to visitors"
ON public.organizations
FOR SELECT
TO anon
USING (state <> 'PENDING');

CREATE POLICY "Enable read access to signed-in users"
ON public.organizations
FOR SELECT
TO authenticated
USING (state <> 'PENDING' OR (SELECT public.caller_is_verified()));

ALTER POLICY "Allow authenticated users to create pending organizations"
ON public.organizations TO authenticated;

-- ====================================================================
-- Visitors can't call internal helpers
-- ====================================================================
-- Supabase grants anon EXECUTE directly, so revoking from PUBLIC wasn't
-- enough.

ALTER FUNCTION public.user_has_pending_organization(text) SET search_path = public;

REVOKE EXECUTE ON FUNCTION public.is_admin(integer) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.user_has_pending_organization(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.caller_is_site_admin() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_user_admin_organizations() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_user_creator_organizations() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.update_profile_picture(text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.is_admin(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.user_has_pending_organization(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.caller_is_site_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_admin_organizations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_creator_organizations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_profile_picture(text) TO authenticated;

-- not created by any migration, but exists on some databases
DO $$
BEGIN
    IF to_regprocedure('public.set_attendance_status(integer, integer, text)') IS NOT NULL THEN
        REVOKE EXECUTE ON FUNCTION public.set_attendance_status(integer, integer, text) FROM PUBLIC, anon;
        GRANT EXECUTE ON FUNCTION public.set_attendance_status(integer, integer, text) TO authenticated;
    END IF;
END $$;

-- ====================================================================
-- Club pictures can only be uploaded by that club's leaders
-- ====================================================================
-- Uploads go to org-pictures/<org id>/<file>, no deeper.

DROP POLICY IF EXISTS "Allow verified users to upload files" ON storage.objects;
CREATE POLICY "Allow verified users to upload files"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'public-files'
    AND (storage.foldername(name))[1] = 'org-pictures'
    AND array_length(storage.foldername(name), 1) = 2
    AND (
        (SELECT public.caller_is_site_admin())
        OR EXISTS (
            SELECT 1
            FROM public.memberships m
            JOIN public.users u ON u.id = m.user_id
            WHERE u.email = (auth.jwt() ->> 'email')
              AND m.active
              AND m.role IN ('CREATOR', 'ADMIN')
              AND m.organization_id::text = (storage.foldername(name))[2]
        )
    )
);

-- Only images, so an uploaded SVG or HTML page can't run script on the
-- storage origin. Club pictures are the bucket's only use.
DO $$
BEGIN
    IF to_regclass('storage.buckets') IS NOT NULL THEN
        INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
        VALUES ('public-files', 'public-files', true, 5242880,
                ARRAY['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
        ON CONFLICT (id) DO UPDATE
        SET file_size_limit = EXCLUDED.file_size_limit,
            allowed_mime_types = EXCLUDED.allowed_mime_types;
    END IF;
END $$;

-- ====================================================================
-- Profile pictures are Google avatars
-- ====================================================================
-- Anything else (javascript: links, tracking pixels) is refused.

CREATE OR REPLACE FUNCTION public.update_profile_picture(profile_url text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF profile_url IS NULL
       OR char_length(profile_url) > 255
       OR profile_url !~ '^https://lh[0-9]+\.googleusercontent\.com/[^\s"''<>\\]*$' THEN
        RAISE EXCEPTION 'Profile pictures must come from your Google account.' USING ERRCODE = '22023';
    END IF;

    UPDATE users
    SET picture = profile_url
    WHERE users.email = auth.jwt() ->> 'email';

    RETURN FOUND;
END;
$$;

-- ====================================================================
-- Nobody raises their own club role
-- ====================================================================
-- The admin update policy lets admins and advisors edit their own row,
-- which let an advisor make themselves ADMIN. Only the club's creator (or a
-- site admin) makes admins, and nobody moves a membership to another person
-- or club.

CREATE OR REPLACE FUNCTION public.guard_membership_role()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    me integer;
    rank_old integer := array_position(ARRAY['MEMBER', 'ADVISOR', 'ADMIN', 'CREATOR'], OLD.role::text);
    rank_new integer := array_position(ARRAY['MEMBER', 'ADVISOR', 'ADMIN', 'CREATOR'], NEW.role::text);
BEGIN
    IF current_user NOT IN ('authenticated', 'anon') OR public.caller_is_site_admin() THEN
        RETURN NEW;
    END IF;
    IF NEW.user_id IS DISTINCT FROM OLD.user_id
       OR NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
        RAISE EXCEPTION 'A membership can''t be moved to someone else.' USING ERRCODE = '42501';
    END IF;
    IF NEW.role IS NOT DISTINCT FROM OLD.role THEN
        RETURN NEW;
    END IF;
    SELECT u.id INTO me FROM users u WHERE u.email = (auth.jwt() ->> 'email');
    IF NEW.user_id = me AND rank_new > rank_old THEN
        RAISE EXCEPTION 'You can''t raise your own role.' USING ERRCODE = '42501';
    END IF;
    IF NEW.role IN ('ADMIN', 'CREATOR') AND NOT EXISTS (
        SELECT 1 FROM memberships m
        WHERE m.organization_id = NEW.organization_id
          AND m.user_id = me
          AND m.role = 'CREATOR'
          AND m.active
    ) THEN
        RAISE EXCEPTION 'Only the Activity''s creator can make someone an admin.' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_membership_role ON public.memberships;
CREATE TRIGGER guard_membership_role
    BEFORE UPDATE OF role, user_id, organization_id ON public.memberships
    FOR EACH ROW EXECUTE FUNCTION public.guard_membership_role();

-- ====================================================================
-- Ended meetings stay
-- ====================================================================
-- Like edits (039), only site admins delete a meeting that has ended, so
-- its attendance isn't lost. Site admins have their own policy.

DROP POLICY IF EXISTS "Enable delete access to admins of organization" ON public.meetings;
CREATE POLICY "Enable delete access to admins of organization"
ON public.meetings
FOR DELETE
TO authenticated
USING (
    end_time > now()
    AND organization_id IN (SELECT public.caller_organizations('{ADMIN,CREATOR,ADVISOR}'))
);

-- ====================================================================
-- Indexes for room checks, calendars and RLS lookups
-- ====================================================================

CREATE INDEX IF NOT EXISTS meetings_room_start_idx ON public.meetings (room_id, start_time);
CREATE INDEX IF NOT EXISTS meetings_org_start_idx ON public.meetings (organization_id, start_time);
CREATE INDEX IF NOT EXISTS memberships_user_idx ON public.memberships (user_id);

-- ====================================================================
-- Meetings must end after they start
-- ====================================================================
-- A few old rows end at or before their start; give them one minute so
-- later edits to those rows don't fail the check. Booking triggers are off
-- for this fix-up: a stretched row may touch a neighbouring booking.

DO $$
DECLARE
    trg text;
    enabled text[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.meetings WHERE end_time <= start_time) THEN
        RETURN;
    END IF;
    SELECT coalesce(array_agg(tgname), '{}') INTO enabled
    FROM pg_trigger
    WHERE tgrelid = 'public.meetings'::regclass AND NOT tgisinternal AND tgenabled <> 'D';
    FOREACH trg IN ARRAY enabled LOOP
        EXECUTE format('ALTER TABLE public.meetings DISABLE TRIGGER %I', trg);
    END LOOP;
    UPDATE public.meetings
    SET end_time = start_time + interval '1 minute'
    WHERE end_time <= start_time;
    FOREACH trg IN ARRAY enabled LOOP
        EXECUTE format('ALTER TABLE public.meetings ENABLE TRIGGER %I', trg);
    END LOOP;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.meetings'::regclass
          AND conname = 'meetings_end_after_start'
    ) THEN
        ALTER TABLE public.meetings
            ADD CONSTRAINT meetings_end_after_start
            CHECK (end_time > start_time);
    END IF;
END $$;

ALTER TABLE public.meetings VALIDATE CONSTRAINT meetings_end_after_start;


-- ####################################################################
-- Part 3: room changes
-- ####################################################################
-- Room changes that cancel meetings (Force Reserve, deleting a room, taking
-- days off a room) each run as one transaction, so a failure part way can't
-- leave meetings deleted without the change. The edge functions email the
-- clubs only after these commit.
-- Also marks Force Reserve bookings, enforces the 5-meeting cap and keeps
-- room names trimmed and unique ignoring case.

-- Force Reserve bookings, which keep their room when its days change
ALTER TABLE public.meetings
  ADD COLUMN IF NOT EXISTS reserved_by_admin BOOLEAN NOT NULL DEFAULT false;

-- earlier ones are only marked by their description
UPDATE public.meetings
SET reserved_by_admin = true
WHERE NOT reserved_by_admin
  AND description = 'This meeting was reserved by an admin.'
  AND end_time > start_time;

-- Books the room for a club, cancelling the meetings it overlaps (touching
-- counts, like get_booked_rooms). Returns the new meeting's id and the
-- cancelled meetings so the caller can email their clubs.
CREATE OR REPLACE FUNCTION public.force_reserve(
  target_room INT,
  target_org INT,
  starts TIMESTAMPTZ,
  ends TIMESTAMPTZ,
  meeting_title TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  label TEXT := nullif(left(btrim(coalesce(meeting_title, '')), 500), '');
  org_state TEXT;
  room_label TEXT;
  room_ais TEXT[];
  new_id INT;
  cancelled JSONB;
BEGIN
  IF NOT public.caller_is_site_admin() THEN
    RAISE EXCEPTION 'Only site admins can force reserve rooms.'
      USING ERRCODE = 'EP403';
  END IF;

  IF starts IS NULL OR ends IS NULL OR ends <= starts THEN
    RAISE EXCEPTION 'Invalid start or end time.' USING ERRCODE = 'EP400';
  END IF;
  IF ends <= now() THEN
    RAISE EXCEPTION 'This time has already ended. Choose a time that ends in the future.'
      USING ERRCODE = 'EP400';
  END IF;

  SELECT o.state::text INTO org_state FROM organizations o WHERE o.id = target_org;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Organization not found.' USING ERRCODE = 'EP404';
  END IF;
  -- a charter still under review (or turned down) isn't a club yet
  IF org_state IN ('PENDING', 'REJECTED') THEN
    RAISE EXCEPTION 'This organization isn''t approved.'
      USING ERRCODE = 'EP409';
  END IF;

  SELECT r.name, r.ais_days INTO room_label, room_ais
  FROM rooms r WHERE r.id = target_room;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room not found.' USING ERRCODE = 'EP404';
  END IF;
  IF to_char(starts AT TIME ZONE 'America/New_York', 'FMDAY') = ANY (coalesce(room_ais, '{}')) THEN
    RAISE EXCEPTION 'This room is reserved for AIS on this day and cannot be booked.'
      USING ERRCODE = 'EP400';
  END IF;

  -- room lock first: this inserts a meeting, so with rows locked first a
  -- second call could lock the new row and then wait for the room (deadlock)
  PERFORM pg_advisory_xact_lock(hashtext('room-booking'), target_room);

  -- meetings that have ended are kept
  IF EXISTS (
    SELECT 1 FROM meetings m
    WHERE m.room_id = target_room
      AND m.start_time <= ends
      AND m.end_time >= starts
      AND m.end_time <= now()
  ) THEN
    RAISE EXCEPTION 'A meeting that has already ended overlaps this time. Start the reservation after it.'
      USING ERRCODE = 'EP409';
  END IF;

  WITH removed AS (
    DELETE FROM meetings m
    WHERE m.room_id = target_room
      AND m.start_time <= ends
      AND m.end_time >= starts
      AND m.end_time > now()
    RETURNING m.id, m.title, m.start_time, m.organization_id
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', removed.id,
    'title', removed.title,
    'start_time', removed.start_time,
    'room_name', room_label,
    'organization_id', removed.organization_id
  ) ORDER BY removed.start_time), '[]'::jsonb) INTO cancelled
  FROM removed;

  INSERT INTO meetings (
    room_id, organization_id, start_time, end_time, title, description, reserved_by_admin
  )
  VALUES (
    target_room, target_org, starts, ends, coalesce(label, 'Reserved Meeting'),
    'This meeting was reserved by an admin.', true
  )
  RETURNING id INTO new_id;

  RETURN jsonb_build_object(
    'meeting_id', new_id,
    'room_name', room_label,
    'cancelled', cancelled
  );
END;
$$;

REVOKE ALL ON FUNCTION public.force_reserve(INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.force_reserve(INT, INT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO authenticated;

-- Deletes a room: its meetings that haven't started are cancelled (and
-- returned for the emails), older ones just lose the room.
CREATE OR REPLACE FUNCTION public.delete_room(target_room INT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  room_label TEXT;
  cancelled JSONB;
BEGIN
  IF NOT public.caller_is_site_admin() THEN
    RAISE EXCEPTION 'Only site admins can delete rooms.' USING ERRCODE = 'EP403';
  END IF;

  SELECT r.name INTO room_label FROM rooms r WHERE r.id = target_room;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room not found.' USING ERRCODE = 'EP404';
  END IF;

  PERFORM 1 FROM meetings m
  WHERE m.room_id = target_room
  ORDER BY m.id
  FOR UPDATE;

  PERFORM pg_advisory_xact_lock(hashtext('room-booking'), target_room);

  WITH removed AS (
    DELETE FROM meetings m
    WHERE m.room_id = target_room
      AND m.start_time >= now()
    RETURNING m.id, m.title, m.start_time, m.organization_id
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', removed.id,
    'title', removed.title,
    'start_time', removed.start_time,
    'room_name', room_label,
    'organization_id', removed.organization_id
  ) ORDER BY removed.start_time), '[]'::jsonb) INTO cancelled
  FROM removed;

  UPDATE meetings SET room_id = NULL WHERE room_id = target_room;
  DELETE FROM rooms WHERE id = target_room;

  RETURN jsonb_build_object('room_name', room_label, 'cancelled', cancelled);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_room(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_room(INT) TO authenticated;

-- Room names are stored trimmed and unique ignoring case. Clashing or blank
-- names must be fixed by a person first (see the prod pre-check).
DO $$
DECLARE
  clashes text;
BEGIN
  SELECT string_agg(ids, '; ') INTO clashes FROM (
    SELECT string_agg(id::text, ', ' ORDER BY id) AS ids
    FROM public.rooms
    GROUP BY lower(regexp_replace(name, '^\s+|\s+$', '', 'g'))
    HAVING count(*) > 1
  ) c;
  IF clashes IS NOT NULL THEN
    RAISE EXCEPTION 'Rooms whose names differ only by case or spaces (ids: %). Rename or merge them, then apply this migration again.', clashes;
  END IF;
  SELECT string_agg(id::text, ', ' ORDER BY id) INTO clashes
  FROM public.rooms WHERE regexp_replace(name, '^\s+|\s+$', '', 'g') = '';
  IF clashes IS NOT NULL THEN
    RAISE EXCEPTION 'Rooms with blank names (ids: %). Rename them, then apply this migration again.', clashes;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.trim_room_name()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.name := regexp_replace(NEW.name, '^\s+|\s+$', '', 'g');
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trim_room_name() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trim_room_name ON public.rooms;
CREATE TRIGGER trim_room_name
BEFORE INSERT OR UPDATE OF name ON public.rooms
FOR EACH ROW EXECUTE FUNCTION public.trim_room_name();

UPDATE public.rooms SET name = name WHERE name ~ '^\s|\s$';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rooms_name_not_blank') THEN
    ALTER TABLE public.rooms ADD CONSTRAINT rooms_name_not_blank CHECK (name <> '');
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS rooms_name_lower_key ON public.rooms (lower(name));

-- Saves a room. Only days taken off the room cancel its upcoming meetings on
-- those days, and not ones that may be there anyway: clubs with a grant for
-- the room, admin clubs and Force Reserve bookings. New AIS days cancel every
-- upcoming meeting on them except Force Reserve bookings.
CREATE OR REPLACE FUNCTION public.update_room(
  target_room INT,
  room_name TEXT,
  room_floor INT,
  room_approval_required BOOLEAN,
  room_comments TEXT,
  room_available_days TEXT[],
  room_ais_days TEXT[]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  week CONSTANT TEXT[] := ARRAY['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY'];
  label TEXT := regexp_replace(coalesce(room_name, ''), '^\s+|\s+$', '', 'g');
  old_days TEXT[];
  old_ais TEXT[];
  removed_days TEXT[];
  added_ais TEXT[];
  cancelled JSONB := '[]'::jsonb;
BEGIN
  IF NOT public.caller_is_site_admin() THEN
    RAISE EXCEPTION 'Only site admins can edit rooms.' USING ERRCODE = 'EP403';
  END IF;
  IF label = '' THEN
    RAISE EXCEPTION 'Room name is required.' USING ERRCODE = 'EP400';
  END IF;
  IF length(label) > 255 THEN
    RAISE EXCEPTION 'Room name must be at most 255 characters.' USING ERRCODE = 'EP400';
  END IF;
  IF room_floor IS NULL THEN
    RAISE EXCEPTION 'Room floor is required.' USING ERRCODE = 'EP400';
  END IF;
  IF room_available_days IS NULL OR NOT room_available_days <@ week THEN
    RAISE EXCEPTION 'Available days must be Monday to Friday.' USING ERRCODE = 'EP400';
  END IF;
  IF room_ais_days IS NOT NULL AND NOT room_ais_days <@ week THEN
    RAISE EXCEPTION 'AIS days must be Monday to Friday.' USING ERRCODE = 'EP400';
  END IF;
  -- once each, Monday first
  room_available_days := array(SELECT d FROM unnest(week) AS d WHERE d = ANY (room_available_days));
  IF room_ais_days IS NOT NULL THEN
    room_ais_days := array(SELECT d FROM unnest(week) AS d WHERE d = ANY (room_ais_days));
  END IF;

  -- NO KEY so bookings (which key-share the room) aren't blocked
  SELECT array(
    SELECT btrim(d) FROM unnest(string_to_array(r.available_days, ',')) AS d
  ), coalesce(r.ais_days, '{}') INTO old_days, old_ais
  FROM rooms r WHERE r.id = target_room
  FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room not found.' USING ERRCODE = 'EP404';
  END IF;

  removed_days := array(
    SELECT d FROM unnest(old_days) AS d WHERE d <> ALL (room_available_days)
  );
  added_ais := array(
    SELECT d FROM unnest(coalesce(room_ais_days, '{}')) AS d WHERE d <> ALL (old_ais)
  );

  IF cardinality(removed_days) > 0 OR cardinality(added_ais) > 0 THEN
    PERFORM 1 FROM meetings m
    WHERE m.room_id = target_room AND m.start_time >= now()
    ORDER BY m.id
    FOR UPDATE;

    PERFORM pg_advisory_xact_lock(hashtext('room-booking'), target_room);

    WITH removed AS (
      DELETE FROM meetings m
      WHERE m.room_id = target_room
        AND m.start_time >= now()
        AND NOT m.reserved_by_admin
        AND (
          to_char(m.start_time AT TIME ZONE 'America/New_York', 'FMDAY') = ANY (added_ais)
          OR (
            to_char(m.start_time AT TIME ZONE 'America/New_York', 'FMDAY') = ANY (removed_days)
            AND NOT EXISTS (
              SELECT 1 FROM room_grants g
              WHERE g.room_id = target_room AND g.organization_id = m.organization_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM organizations o
              WHERE o.id = m.organization_id AND o.state = 'ADMIN'
            )
          )
        )
      RETURNING m.id, m.title, m.start_time, m.organization_id
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', removed.id,
      'title', removed.title,
      'start_time', removed.start_time,
      'room_name', label,
      'organization_id', removed.organization_id
    ) ORDER BY removed.start_time), '[]'::jsonb) INTO cancelled
    FROM removed;
  END IF;

  UPDATE rooms SET
    name = label,
    floor = room_floor,
    approval_required = room_approval_required,
    comments = room_comments,
    available_days = array_to_string(room_available_days, ', '),
    ais_days = room_ais_days
  WHERE id = target_room
  RETURNING name INTO label;

  RETURN jsonb_build_object('cancelled', cancelled, 'room_name', label);
END;
$$;

REVOKE ALL ON FUNCTION public.update_room(INT, TEXT, INT, BOOLEAN, TEXT, TEXT[], TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_room(INT, TEXT, INT, BOOLEAN, TEXT, TEXT[], TEXT[]) TO authenticated;

-- At most 5 meetings with a room from today (New York) on per club. A lock
-- per club makes two bookings at once wait for each other. Admin clubs, site
-- admins (Force Reserve) and direct database sessions aren't capped. Fires
-- after prevent_room_double_booking (triggers run in name order), so the
-- room lock is always taken before this one.
CREATE OR REPLACE FUNCTION public.room_meeting_cap()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  today_start TIMESTAMPTZ :=
    date_trunc('day', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York';
BEGIN
  IF NEW.room_id IS NULL OR NEW.start_time < today_start THEN
    RETURN NEW;
  END IF;
  -- already counted
  IF TG_OP = 'UPDATE' AND OLD.room_id IS NOT NULL AND OLD.start_time >= today_start THEN
    RETURN NEW;
  END IF;
  IF auth.jwt() IS NULL OR public.caller_is_site_admin() THEN
    RETURN NEW;
  END IF;
  IF EXISTS (
    SELECT 1 FROM organizations o
    WHERE o.id = NEW.organization_id AND o.state = 'ADMIN'
  ) THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('room-meeting-cap'), NEW.organization_id);

  IF (
    SELECT count(*) FROM meetings m
    WHERE m.organization_id = NEW.organization_id
      AND m.room_id IS NOT NULL
      AND m.id <> NEW.id
      AND m.start_time >= today_start
  ) >= 5 THEN
    RAISE EXCEPTION 'Due to high demand, only 5 future in-person meetings can be booked per club.'
      USING ERRCODE = 'EP429';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.room_meeting_cap() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS room_meeting_cap ON public.meetings;
CREATE TRIGGER room_meeting_cap
BEFORE INSERT OR UPDATE OF room_id, start_time ON public.meetings
FOR EACH ROW EXECUTE FUNCTION public.room_meeting_cap();

NOTIFY pgrst, 'reload schema';


-- ####################################################################
-- Part 4: schema cleanup
-- ####################################################################
-- Schema cleanup.

-- ====================================================================
-- Remove the unused Google Calendar sync tables
-- ====================================================================
-- The sync never worked in production and its code is gone. Their foreign
-- keys had no ON DELETE, so a single row would block deleting a meeting or
-- changing a club's URL. Refuse if anything was ever stored.

DO $$
DECLARE
    t text;
    n bigint;
BEGIN
    FOREACH t IN ARRAY ARRAY['googlecalendarevents', 'googlecalendars', 'backgroundtokens'] LOOP
        IF to_regclass('public.' || t) IS NOT NULL THEN
            EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
            IF n > 0 THEN
                RAISE EXCEPTION '% has % rows; check before dropping', t, n;
            END IF;
        END IF;
    END LOOP;
END $$;

DROP TABLE IF EXISTS public.googlecalendarevents;
DROP TABLE IF EXISTS public.googlecalendars;
DROP TABLE IF EXISTS public.backgroundtokens;

-- ====================================================================
-- users.email
-- ====================================================================
-- It was unique twice. Sign-in compares emails exactly, so store them
-- trimmed and lowercase.

ALTER TABLE public.users DROP CONSTRAINT IF EXISTS unique_email;

CREATE OR REPLACE FUNCTION public.normalize_user_email()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    NEW.email := lower(trim(NEW.email));
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.normalize_user_email() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS normalize_user_email ON public.users;
CREATE TRIGGER normalize_user_email
    BEFORE INSERT OR UPDATE OF email ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.normalize_user_email();

-- Accounts that differ only by case must be merged by a person first (see
-- the pre-check in the prod steps); stop rather than skip the unique index.
DO $$
DECLARE
    clashes text;
BEGIN
    SELECT string_agg(ids, '; ') INTO clashes FROM (
        SELECT string_agg(id::text, ', ' ORDER BY id) AS ids
        FROM public.users GROUP BY lower(trim(email)) HAVING count(*) > 1
    ) c;
    IF clashes IS NOT NULL THEN
        RAISE EXCEPTION 'Users whose emails differ only by case (ids: %). Merge each group into one account (move its memberships, then delete the others), then apply this migration again.', clashes;
    END IF;
END $$;

-- a case-only change isn't a new email, so it mustn't re-add an advisor the
-- club removed (051's trigger compared emails exactly)
DROP TRIGGER IF EXISTS add_charter_advisor_for_updated_user ON public.users;
CREATE TRIGGER add_charter_advisor_for_updated_user
    AFTER UPDATE OF is_faculty, email ON public.users
    FOR EACH ROW
    WHEN (
        NEW.is_faculty
        AND (OLD.is_faculty IS DISTINCT FROM NEW.is_faculty
            OR lower(trim(OLD.email)) IS DISTINCT FROM lower(trim(NEW.email)))
    )
    EXECUTE FUNCTION public.add_charter_advisor_for_user();

UPDATE public.users SET email = lower(trim(email)) WHERE email <> lower(trim(email));

CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_key ON public.users (lower(email));

-- Charter edits never set fair; its old default made every approval clear it.
ALTER TABLE public.organizationedits ALTER COLUMN fair DROP DEFAULT;
UPDATE public.organizationedits SET fair = NULL WHERE fair IS NOT NULL;

-- ====================================================================
-- Day lists only hold weekdays
-- ====================================================================

-- older saves left a leading ", " in rooms.available_days
UPDATE public.rooms
SET available_days = array_to_string(
    ARRAY(
        SELECT d FROM unnest(string_to_array(available_days, ',')) WITH ORDINALITY AS x(raw, i)
        CROSS JOIN LATERAL (SELECT upper(trim(raw)) AS d) y
        WHERE d IN ('MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY')
        ORDER BY i
    ),
    ', '
)
WHERE available_days IS NOT NULL
  AND available_days !~ '^((MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY)(, (MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY))*)?$';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rooms_available_days_check') THEN
        ALTER TABLE public.rooms ADD CONSTRAINT rooms_available_days_check CHECK (
            available_days ~ '^((MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY)(, (MONDAY|TUESDAY|WEDNESDAY|THURSDAY|FRIDAY))*)?$'
        );
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rooms_ais_days_check') THEN
        ALTER TABLE public.rooms ADD CONSTRAINT rooms_ais_days_check CHECK (
            ais_days <@ ARRAY['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY']::text[]
        ) NOT VALID;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organizations_meeting_days_check') THEN
        ALTER TABLE public.organizations ADD CONSTRAINT organizations_meeting_days_check CHECK (
            meeting_days <@ ARRAY['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY']::text[]
        ) NOT VALID;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organizationedits_meeting_days_check') THEN
        ALTER TABLE public.organizationedits ADD CONSTRAINT organizationedits_meeting_days_check CHECK (
            meeting_days <@ ARRAY['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY']::text[]
        ) NOT VALID;
    END IF;
END $$;

-- ====================================================================
-- Deleting a user no longer fails on old references
-- ====================================================================

ALTER TABLE public.permissions DROP CONSTRAINT IF EXISTS permissions_user_id_fkey;
ALTER TABLE public.permissions ADD CONSTRAINT permissions_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE public.strikes ALTER COLUMN admin_id DROP NOT NULL;
ALTER TABLE public.strikes DROP CONSTRAINT IF EXISTS strikes_admin_id_fkey;
ALTER TABLE public.strikes ADD CONSTRAINT strikes_admin_id_fkey
    FOREIGN KEY (admin_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE public.valentinesmessages DROP CONSTRAINT IF EXISTS valentinesmessages_sender_fkey;
ALTER TABLE public.valentinesmessages ADD CONSTRAINT valentinesmessages_sender_fkey
    FOREIGN KEY (sender) REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE public.valentinesmessages DROP CONSTRAINT IF EXISTS valentinesmessages_receiver_fkey;
ALTER TABLE public.valentinesmessages ADD CONSTRAINT valentinesmessages_receiver_fkey
    FOREIGN KEY (receiver) REFERENCES public.users(id) ON DELETE CASCADE;
ALTER TABLE public.valentinesmessages ALTER COLUMN verified_by DROP NOT NULL;
ALTER TABLE public.valentinesmessages DROP CONSTRAINT IF EXISTS valentinesmessages_verified_by_fkey;
ALTER TABLE public.valentinesmessages ADD CONSTRAINT valentinesmessages_verified_by_fkey
    FOREIGN KEY (verified_by) REFERENCES public.users(id) ON DELETE SET NULL;


-- ####################################################################
-- Part 5: features
-- ####################################################################
-- Features.

-- ====================================================================
-- Announcements: expiry and pinning
-- ====================================================================
-- Readers skip announcements whose ends_at has passed; pinned ones go first.

ALTER TABLE public.announcements ADD COLUMN IF NOT EXISTS ends_at timestamptz;
ALTER TABLE public.announcements ADD COLUMN IF NOT EXISTS pinned boolean NOT NULL DEFAULT false;

-- ====================================================================
-- SU analytics
-- ====================================================================
-- Counts for the admin dashboard. Aggregates only, no names or emails;
-- site admins only. Weeks and days are New York time.

CREATE OR REPLACE FUNCTION public.su_analytics(weeks integer DEFAULT 12)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    tz constant text := 'America/New_York';
    today date := (now() AT TIME ZONE tz)::date;
    first_week date;
    window_start timestamptz;
    result jsonb;
BEGIN
    IF NOT public.caller_is_site_admin() THEN
        RAISE EXCEPTION 'Only site admins can see analytics' USING ERRCODE = '42501';
    END IF;

    weeks := least(greatest(coalesce(weeks, 12), 1), 52);
    first_week := date_trunc('week', today)::date - (weeks - 1) * 7;
    window_start := first_week::timestamp AT TIME ZONE tz;

    WITH
    past AS (
        SELECT m.id, m.organization_id, m.room_id,
               (m.start_time AT TIME ZONE tz)::date AS day
        FROM meetings m
        WHERE m.start_time >= window_start AND m.start_time < now()
    ),
    -- weekdays each room is open for booking, minus blocked days
    open_days AS (
        SELECT r.id AS room_id, d::date AS day
        FROM rooms r
        CROSS JOIN generate_series(first_week, today, interval '1 day') d
        WHERE extract(isodow FROM d) <= 5
          AND trim(to_char(d, 'FMDAY')) = ANY (string_to_array(r.available_days, ', '))
          AND NOT EXISTS (
              SELECT 1 FROM room_blocks b WHERE b.room_id = r.id AND b.blocked_on = d::date
          )
    ),
    booked_open AS (
        SELECT DISTINCT o.room_id, o.day
        FROM open_days o
        JOIN past p ON p.room_id = o.room_id AND p.day = o.day
    ),
    taken AS (
        SELECT p.id, p.organization_id, count(a.id) AS attendees
        FROM past p
        JOIN attendance a ON a.meeting_id = p.id
        GROUP BY p.id, p.organization_id
    ),
    roster AS (
        SELECT organization_id, count(*) AS members
        FROM memberships
        WHERE active AND role <> 'ADVISOR'
        GROUP BY organization_id
    )
    SELECT jsonb_build_object(
        'generated_at', now(),
        'weeks', weeks,
        'since', first_week,
        'clubs_by_state', (
            SELECT coalesce(jsonb_agg(jsonb_build_object('state', state, 'count', n) ORDER BY n DESC), '[]')
            FROM (SELECT state::text AS state, count(*) AS n FROM organizations GROUP BY state) s
        ),
        'clubs_meeting', (SELECT count(DISTINCT organization_id) FROM past),
        'meetings_per_week', (
            SELECT jsonb_agg(jsonb_build_object('week', w::date, 'count', coalesce(c.n, 0)) ORDER BY w)
            FROM generate_series(first_week, date_trunc('week', today)::date, interval '7 days') w
            LEFT JOIN (
                SELECT date_trunc('week', m.start_time AT TIME ZONE tz)::date AS wk, count(*) AS n
                FROM meetings m
                WHERE m.start_time >= window_start
                  AND m.start_time < (date_trunc('week', today)::date + 7)::timestamp AT TIME ZONE tz
                GROUP BY 1
            ) c ON c.wk = w::date
        ),
        'busiest_rooms', (
            SELECT coalesce(jsonb_agg(x ORDER BY (x ->> 'meetings')::int DESC, x ->> 'room'), '[]')
            FROM (
                SELECT jsonb_build_object(
                    'room', r.name,
                    'meetings', count(*),
                    'open_days', (SELECT count(*) FROM open_days o WHERE o.room_id = r.id),
                    'booked_days', (SELECT count(*) FROM booked_open b WHERE b.room_id = r.id)
                ) AS x
                FROM past p JOIN rooms r ON r.id = p.room_id
                GROUP BY r.id, r.name
                ORDER BY count(*) DESC, r.name
                LIMIT 10
            ) t
        ),
        'room_days_open', (SELECT count(*) FROM open_days),
        'room_days_booked', (SELECT count(*) FROM booked_open),
        'meetings_held', (SELECT count(*) FROM past),
        'meetings_with_attendance', (SELECT count(*) FROM taken),
        'attendees', (SELECT coalesce(sum(attendees), 0) FROM taken),
        'expected', (
            SELECT coalesce(sum(greatest(coalesce(r.members, 0), t.attendees)), 0)
            FROM taken t LEFT JOIN roster r ON r.organization_id = t.organization_id
        )
    ) INTO result;

    RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.su_analytics(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.su_analytics(integer) TO authenticated;


-- ####################################################################
-- Part 6: features, part 2
-- ####################################################################
-- Features, part 2.
-- 'REJECTED' is new in this transaction, so policies and SQL functions
-- compare state as text (Postgres can't use a new enum value before COMMIT).

-- ====================================================================
-- Rejected charters stay so they can be fixed; admins explain through Messages
-- ====================================================================

ALTER TYPE public.org_state ADD VALUE IF NOT EXISTS 'REJECTED';

ALTER TABLE public.organizations ADD COLUMN IF NOT EXISTS rejected_at timestamptz;

-- same as 055's, so either can be applied first
CREATE OR REPLACE FUNCTION public.current_user_id()
RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT u.id FROM users AS u WHERE u.email = (auth.jwt() ->> 'email');
$$;

REVOKE ALL ON FUNCTION public.current_user_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_id() TO authenticated;

CREATE OR REPLACE FUNCTION public.caller_leads_organization(org_id integer)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM memberships m
        WHERE m.organization_id = org_id
          AND m.user_id = public.current_user_id()
          AND m.active
          AND m.role IN ('CREATOR', 'ADMIN')
    );
$$;

REVOKE ALL ON FUNCTION public.caller_leads_organization(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.caller_leads_organization(integer) TO authenticated;

-- rejected charters: only their leaders and site admins
DROP POLICY IF EXISTS "Enable read access to visitors" ON public.organizations;
CREATE POLICY "Enable read access to visitors"
ON public.organizations
FOR SELECT
TO anon
USING (state::text NOT IN ('PENDING', 'REJECTED'));

DROP POLICY IF EXISTS "Enable read access to signed-in users" ON public.organizations;
CREATE POLICY "Enable read access to signed-in users"
ON public.organizations
FOR SELECT
TO authenticated
USING (
    state::text NOT IN ('PENDING', 'REJECTED')
    OR (state::text = 'PENDING' AND (SELECT public.caller_is_verified()))
    OR (
        state::text = 'REJECTED'
        AND ((SELECT public.caller_is_site_admin()) OR public.caller_leads_organization(id))
    )
);

-- leaders edit pending and rejected charters through the update-charter
-- function, which checks every field; only site admins update directly.
-- The trigger below keeps the state and review columns with site admins.
DROP POLICY IF EXISTS "Allow authenticated users to update pending organizations" ON public.organizations;

CREATE OR REPLACE FUNCTION public.guard_organization_review()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF current_user NOT IN ('authenticated', 'anon') OR public.caller_is_site_admin() THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.rejected_at IS NOT NULL THEN
            RAISE EXCEPTION 'Only the Student Union can reject a charter.' USING ERRCODE = '42501';
        END IF;
    ELSIF NEW.state IS DISTINCT FROM OLD.state
       OR NEW.rejected_at IS DISTINCT FROM OLD.rejected_at THEN
        RAISE EXCEPTION 'Only the Student Union can change a charter''s review status.' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_organization_review ON public.organizations;
CREATE TRIGGER guard_organization_review
    BEFORE INSERT OR UPDATE ON public.organizations
    FOR EACH ROW EXECUTE FUNCTION public.guard_organization_review();

-- creators may only delete charters that aren't approved yet
DROP POLICY IF EXISTS "Allow authenticated users to delete their own organization" ON public.organizations;
CREATE POLICY "Allow authenticated users to delete their own organization"
ON public.organizations
FOR DELETE
TO authenticated
USING (
    state::text IN ('PENDING', 'REJECTED')
    AND id IN (SELECT public.caller_organizations('{CREATOR}'))
);

-- Sends a fixed charter back for review. Raises with messages for people.
CREATE OR REPLACE FUNCTION public.resubmit_organization(org_id integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.caller_leads_organization(org_id) THEN
        RAISE EXCEPTION 'Only this Activity''s leaders can resubmit its charter.' USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = org_id AND state = 'REJECTED') THEN
        RAISE EXCEPTION 'This charter isn''t waiting for changes.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM memberships c
        JOIN memberships other ON other.user_id = c.user_id AND other.role = 'CREATOR'
        JOIN organizations o ON o.id = other.organization_id
        WHERE c.organization_id = org_id
          AND c.role = 'CREATOR'
          AND o.id <> org_id
          AND o.state = 'PENDING'
    ) THEN
        RAISE EXCEPTION 'The creator already has a charter waiting for review.';
    END IF;

    UPDATE organizations SET state = 'PENDING' WHERE id = org_id AND state = 'REJECTED';
END;
$$;

REVOKE ALL ON FUNCTION public.resubmit_organization(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resubmit_organization(integer) TO authenticated;

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
      AND (o.state::text NOT IN ('PENDING', 'PUNISHED', 'REJECTED'))
    )
  ))
  AND (active = false)
  AND (role = 'MEMBER')
  AND (role_name IS NULL)
);

-- a faculty account doesn't become advisor of a rejected charter
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
  WHERE organizations.state NOT IN ('PENDING', 'REJECTED')
    AND lower(trim(organizations.faculty_email)) = lower(trim(NEW.email));

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.add_charter_advisor_for_user() FROM PUBLIC, anon, authenticated;

-- unchanged from 051 except REJECTED
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
    WHERE organizations.id = org_id AND organizations.state IN ('PENDING', 'PUNISHED', 'REJECTED')
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

-- ====================================================================
-- Admin action log
-- ====================================================================
-- Written by the functions (service role) and the triggers below; site
-- admins can read it. Details hold names, never emails.

CREATE TABLE IF NOT EXISTS public.admin_actions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_id integer REFERENCES public.users (id) ON DELETE SET NULL,
    action text NOT NULL,
    target_type text,
    target_id bigint,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_actions_created_idx ON public.admin_actions (created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS admin_actions_action_idx ON public.admin_actions (action, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_actions_actor_idx ON public.admin_actions (actor_id, created_at DESC);

ALTER TABLE public.admin_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_actions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.admin_actions TO authenticated;
GRANT ALL ON public.admin_actions TO service_role;

DROP POLICY IF EXISTS "Site admins can read the admin log" ON public.admin_actions;
CREATE POLICY "Site admins can read the admin log"
ON public.admin_actions
FOR SELECT
TO authenticated
USING ((SELECT public.caller_is_site_admin()));

-- the actions and admins that appear in the log, for its filters
CREATE OR REPLACE FUNCTION public.admin_action_filters()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.caller_is_site_admin() THEN
        RAISE EXCEPTION 'Only site admins can see the admin log' USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'actions', (
            SELECT coalesce(jsonb_agg(action ORDER BY action), '[]')
            FROM (SELECT DISTINCT action FROM admin_actions) a
        ),
        'actors', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'id', u.id, 'name', trim(u.first_name || ' ' || u.last_name)
            ) ORDER BY u.first_name, u.last_name), '[]')
            FROM users u
            WHERE u.id IN (SELECT DISTINCT actor_id FROM admin_actions)
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_action_filters() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_action_filters() TO authenticated;

-- Admin pages that write tables directly (no function) are logged here.
-- Only site admins acting through the API count; deletes cascading from a
-- removed club or room are skipped.
CREATE OR REPLACE FUNCTION public.log_admin_table_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    actor integer := public.current_user_id();
    added integer;
BEGIN
    IF actor IS NULL OR NOT public.caller_is_site_admin() THEN
        RETURN NULL;
    END IF;

    IF TG_TABLE_NAME = 'users' THEN
        SELECT count(*) INTO added FROM new_users;
        IF added = 1 THEN
            INSERT INTO admin_actions (actor_id, action, target_type, target_id, details)
            SELECT actor, 'add_user', 'user', n.id,
                   jsonb_build_object('name', trim(n.first_name || ' ' || n.last_name), 'is_faculty', n.is_faculty)
            FROM new_users n;
        ELSIF added > 1 THEN
            INSERT INTO admin_actions (actor_id, action, details)
            VALUES (actor, 'add_users', jsonb_build_object('count', added));
        END IF;
    ELSIF TG_TABLE_NAME = 'strikes' THEN
        IF EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
            INSERT INTO admin_actions (actor_id, action, target_type, target_id, details)
            SELECT actor, 'delete_strike', 'organization', OLD.organization_id,
                   jsonb_build_object('organization', o.name, 'reason', OLD.reason)
            FROM organizations o WHERE o.id = OLD.organization_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'room_blocks' THEN
        IF EXISTS (SELECT 1 FROM rooms WHERE id = OLD.room_id) THEN
            INSERT INTO admin_actions (actor_id, action, target_type, target_id, details)
            SELECT actor, 'unblock_room', 'room', OLD.room_id,
                   jsonb_build_object('room', r.name, 'date', OLD.blocked_on)
            FROM rooms r WHERE r.id = OLD.room_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'room_grants' THEN
        IF TG_OP = 'INSERT' THEN
            INSERT INTO admin_actions (actor_id, action, target_type, target_id, details)
            SELECT actor, 'grant_room', 'room', NEW.room_id,
                   jsonb_build_object('room', r.name, 'organization', o.name)
            FROM rooms r, organizations o
            WHERE r.id = NEW.room_id AND o.id = NEW.organization_id;
        ELSE
            INSERT INTO admin_actions (actor_id, action, target_type, target_id, details)
            SELECT actor, 'remove_room_grant', 'room', OLD.room_id,
                   jsonb_build_object('room', r.name, 'organization', o.name)
            FROM rooms r, organizations o
            WHERE r.id = OLD.room_id AND o.id = OLD.organization_id;
        END IF;
    ELSIF TG_TABLE_NAME = 'rooms' THEN
        INSERT INTO admin_actions (actor_id, action, target_type, target_id, details)
        VALUES (actor, 'create_room', 'room', NEW.id, jsonb_build_object('room', NEW.name));
    ELSIF TG_TABLE_NAME = 'announcements' THEN
        INSERT INTO admin_actions (actor_id, action, details)
        VALUES (
            actor,
            CASE TG_OP
                WHEN 'INSERT' THEN 'post_announcement'
                WHEN 'UPDATE' THEN 'edit_announcement'
                ELSE 'delete_announcement'
            END,
            jsonb_build_object('title', left(coalesce(
                CASE WHEN TG_OP = 'DELETE' THEN OLD.content ELSE NEW.content END, ''), 80))
        );
    END IF;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.log_admin_table_change() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS log_admin_user_inserts ON public.users;
CREATE TRIGGER log_admin_user_inserts
    AFTER INSERT ON public.users
    REFERENCING NEW TABLE AS new_users
    FOR EACH STATEMENT EXECUTE FUNCTION public.log_admin_table_change();

DROP TRIGGER IF EXISTS log_admin_strike_deletes ON public.strikes;
CREATE TRIGGER log_admin_strike_deletes
    AFTER DELETE ON public.strikes
    FOR EACH ROW EXECUTE FUNCTION public.log_admin_table_change();

DROP TRIGGER IF EXISTS log_admin_room_unblocks ON public.room_blocks;
CREATE TRIGGER log_admin_room_unblocks
    AFTER DELETE ON public.room_blocks
    FOR EACH ROW EXECUTE FUNCTION public.log_admin_table_change();

DROP TRIGGER IF EXISTS log_admin_room_grants ON public.room_grants;
CREATE TRIGGER log_admin_room_grants
    AFTER INSERT OR DELETE ON public.room_grants
    FOR EACH ROW EXECUTE FUNCTION public.log_admin_table_change();

DROP TRIGGER IF EXISTS log_admin_room_inserts ON public.rooms;
CREATE TRIGGER log_admin_room_inserts
    AFTER INSERT ON public.rooms
    FOR EACH ROW EXECUTE FUNCTION public.log_admin_table_change();

DROP TRIGGER IF EXISTS log_admin_announcements ON public.announcements;
CREATE TRIGGER log_admin_announcements
    AFTER INSERT OR UPDATE OR DELETE ON public.announcements
    FOR EACH ROW EXECUTE FUNCTION public.log_admin_table_change();

-- ====================================================================
-- Calendar feed tokens
-- ====================================================================
-- The secret in a user's personal calendar link. Read your own; make or
-- replace it with calendar_token().

CREATE TABLE IF NOT EXISTS public.calendar_tokens (
    user_id integer PRIMARY KEY REFERENCES public.users (id) ON DELETE CASCADE,
    token text NOT NULL UNIQUE CHECK (token ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now()
);
-- clubs left out of the all-clubs link; ones joined later are in by default
ALTER TABLE public.calendar_tokens
    ADD COLUMN IF NOT EXISTS hidden_organizations integer[] NOT NULL DEFAULT '{}';

ALTER TABLE public.calendar_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.calendar_tokens FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.calendar_tokens TO authenticated;
GRANT ALL ON public.calendar_tokens TO service_role;

DROP POLICY IF EXISTS "Users read their own calendar token" ON public.calendar_tokens;
CREATE POLICY "Users read their own calendar token"
ON public.calendar_tokens
FOR SELECT
TO authenticated
USING (user_id = (SELECT public.current_user_id()));

CREATE OR REPLACE FUNCTION public.calendar_token(regenerate boolean DEFAULT false)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    me integer := public.current_user_id();
    fresh text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    result text;
BEGIN
    IF me IS NULL THEN
        RAISE EXCEPTION 'Sign in with your Epsilon account first.' USING ERRCODE = '42501';
    END IF;

    IF regenerate THEN
        INSERT INTO calendar_tokens (user_id, token) VALUES (me, fresh)
        ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token, created_at = now()
        RETURNING token INTO result;
    ELSE
        INSERT INTO calendar_tokens (user_id, token) VALUES (me, fresh)
        ON CONFLICT (user_id) DO NOTHING;
        SELECT token INTO result FROM calendar_tokens WHERE user_id = me;
    END IF;
    RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.calendar_token(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.calendar_token(boolean) TO authenticated;

-- Saves which clubs to leave out of the caller's all-clubs link.
CREATE OR REPLACE FUNCTION public.set_calendar_hidden_clubs(hidden integer[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    me integer := public.current_user_id();
    list integer[] := coalesce(
        (SELECT array_agg(DISTINCT h ORDER BY h) FROM unnest(hidden) h WHERE h IS NOT NULL),
        '{}'
    );
BEGIN
    IF me IS NULL THEN
        RAISE EXCEPTION 'Sign in with your Epsilon account first.' USING ERRCODE = '42501';
    END IF;
    IF coalesce(cardinality(hidden), 0) > 500 THEN
        RAISE EXCEPTION 'Too many clubs.' USING ERRCODE = '22023';
    END IF;

    -- makes the link too if there isn't one yet
    INSERT INTO calendar_tokens (user_id, token, hidden_organizations)
    VALUES (me, replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), list)
    ON CONFLICT (user_id) DO UPDATE SET hidden_organizations = EXCLUDED.hidden_organizations;
END;
$$;

REVOKE ALL ON FUNCTION public.set_calendar_hidden_clubs(integer[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_calendar_hidden_clubs(integer[]) TO authenticated;

-- ====================================================================
-- Attendance columns made outside the migrations
-- ====================================================================
-- Prod already has these (the CSV reads recorded_at and source). Old rows
-- get their created_at as recorded_at, not the time this runs.

ALTER TABLE public.attendance ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'PRESENT';
ALTER TABLE public.attendance ADD COLUMN IF NOT EXISTS recorded_at timestamptz;
UPDATE public.attendance SET recorded_at = created_at WHERE recorded_at IS NULL;
ALTER TABLE public.attendance ALTER COLUMN recorded_at SET DEFAULT now();
ALTER TABLE public.attendance ADD COLUMN IF NOT EXISTS source text DEFAULT 'SELF';

-- leaders' marks say so; members can't write rows
GRANT INSERT (source), UPDATE (source) ON public.attendance TO authenticated;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'attendance_source_check') THEN
        ALTER TABLE public.attendance ADD CONSTRAINT attendance_source_check
            CHECK (source IN ('SELF', 'LEADER', 'ADMIN')) NOT VALID;
    END IF;
END $$;
ALTER TABLE public.attendance VALIDATE CONSTRAINT attendance_source_check;

-- callers can't pick the source: any insert or update by the club's leaders
-- gives LEADER, by other site admins ADMIN. check_in_to_meeting runs as its
-- owner, so it keeps SELF.
CREATE OR REPLACE FUNCTION public.attendance_source_from_caller()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    IF current_user = 'authenticated' THEN
        NEW.source := CASE
            WHEN NEW.organization_id IN (SELECT public.caller_organizations(
                '{ADMIN,CREATOR,ADVISOR}'::public.org_role[])) THEN 'LEADER'
            ELSE 'ADMIN'
        END;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.attendance_source_from_caller() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS attendance_source_from_caller ON public.attendance;
CREATE TRIGGER attendance_source_from_caller
    BEFORE INSERT OR UPDATE ON public.attendance
    FOR EACH ROW EXECUTE FUNCTION public.attendance_source_from_caller();

-- leaders insert edit requests directly; keywords are at most 50 characters
-- once trimmed, as the functions check (old rows aren't checked)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organizationedits_keywords_length') THEN
        ALTER TABLE public.organizationedits ADD CONSTRAINT organizationedits_keywords_length
            CHECK (keywords !~ '[^,[:space:]][^,]{49,}[^,[:space:]]') NOT VALID;
    END IF;
END $$;


COMMIT;
