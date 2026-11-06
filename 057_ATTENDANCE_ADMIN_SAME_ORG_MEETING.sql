-- Club admins could write attendance rows that pair their own organization_id
-- with a meeting from another club. Require the meeting to belong to the same
-- organization. Apply after 056.

-- supersedes 056_REQUIRE_ACTIVE_ADMIN.sql
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
