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
