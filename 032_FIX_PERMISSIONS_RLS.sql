-- The original policy compared WITH CHECK against the row being
-- inserted, so any authenticated user could just do
-- {user_id: <own users.id>, permission: 'ADMIN'} and give themselves free admin.
-- INSERT/UPDATE/DELETE now require the caller to ALREADY have admin.

DROP POLICY IF EXISTS "Enable all access to site admins" ON public.permissions;

CREATE POLICY "Enable all access to site admins"
ON public.permissions
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users u
    WHERE u.email = (auth.jwt() ->> 'email')
      AND public.is_admin(u.id)
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users u
    WHERE u.email = (auth.jwt() ->> 'email')
      AND public.is_admin(u.id)
  )
);
