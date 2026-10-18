-- Clubs that may book a room regardless of the room's available days.
-- Clubs without a grant follow the room's normal availability.
CREATE TABLE room_grants (
  room_id INT NOT NULL REFERENCES rooms (id) ON DELETE CASCADE,
  organization_id INT NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (room_id, organization_id)
);

ALTER TABLE room_grants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read access to all authenticated users"
ON public.room_grants
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (u.email = (auth.jwt() ->> 'email'))
  )
);

CREATE POLICY "Enable all access to site admins"
ON public.room_grants
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM permissions as p
    INNER JOIN users as u ON (p.user_id = u.id)
    WHERE (
      u.email = auth.jwt() ->> 'email'
      AND p.permission = 'ADMIN'
    )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM permissions as p
    INNER JOIN users as u ON (p.user_id = u.id)
    WHERE (
      u.email = auth.jwt() ->> 'email'
      AND p.permission = 'ADMIN'
    )
  )
);
