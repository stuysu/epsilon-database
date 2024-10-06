CREATE TABLE IF NOT EXISTS membershipnotifications (
  membership_id integer NOT NULL UNIQUE,
  PRIMARY KEY (membership_id),
  FOREIGN KEY (membership_id) REFERENCES memberships(id) on delete cascade,
  allow_notifications boolean DEFAULT TRUE
);

INSERT INTO membershipnotifications (membership_id, allow_notifications)
SELECT id, allow_notifications
FROM memberships;

ALTER TABLE memberships
DROP COLUMN allow_notifications;

ALTER TABLE membershipnotifications ENABLE ROW LEVEL SECURITY;


-- SELECT policy implicitly applies to UPDATE policy as well
CREATE POLICY "Alow users to read/edit their own records"
ON public.membershipnotifications
FOR all
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM users WHERE (
      users.email = auth.jwt() ->> 'email' AND
      users.id = (
        SELECT user_id FROM memberships WHERE id = membership_id
      )
    )
  )
);
