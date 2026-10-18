-- Club admins could change any of their meetings at any time, including ones
-- that already happened. They can now only update meetings that have not ended
-- yet, and cannot move a meeting so that it ends in the past. Site admins have
-- their own policy and are not affected.
DROP POLICY IF EXISTS "Enable update access to admins of organization" ON public.meetings;

CREATE POLICY "Enable update access to admins of organization"
ON public.meetings
FOR UPDATE
TO authenticated
USING (
  public.meetings.end_time > now()
  AND EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = public.meetings.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
)
WITH CHECK (
  public.meetings.end_time > now()
  AND EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = public.meetings.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);
