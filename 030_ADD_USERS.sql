CREATE POLICY "Allow insert for site admin"
ON public.users
TO authenticated
WITH CHECK(
  EXISTS (
    SELECT 1
    FROM users u
    JOIN permissions p ON u.id = p.user_id
    WHERE
      u.email = (jwt() ->> 'email')
      AND p.permission = 'ADMIN'
  )
);

ALTER TABLE users ADD CONSTRAINT unique_email UNIQUE (email);
