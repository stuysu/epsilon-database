CREATE TABLE valentinesmessages (
  id SERIAL PRIMARY KEY,
  sender INT NOT NULL,
  receiver INT NOT NULL,
  message TEXT NOT NULL,
  background VARCHAR(50) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  verified_at TIMESTAMP DEFAULT NULL,
  verified_by INT DEFAULT NULL,
  show_sender BOOLEAN DEFAULT FALSE,
  FOREIGN KEY (sender) REFERENCES users(id),
  FOREIGN KEY (receiver) REFERENCES users(id),
  FOREIGN KEY (verified_by) REFERENCES users(id)
);

ALTER TABLE valentinesmessages ENABLE ROW LEVEL SECURITY;

ALTER TYPE site_perms ADD VALUE 'VALENTINES';

ALTER TABLE settings ADD IF NOT EXISTS visible BOOLEAN DEFAULT FALSE;
-- 2025-02-14 00:00 EST, with seconds precision
INSERT INTO settings (name, setting_value, visible) VALUES ('valentines_deadline', 1739509200, TRUE);
CREATE POLICY "Users can read all visible settings."
ON "public"."settings"
FOR SELECT
TO AUTHENTICATED
USING (visible);

CREATE POLICY "Sender can read their messages."
ON "public"."valentinesmessages"
FOR SELECT
TO authenticated
USING (
  (EXISTS
    ( SELECT 1
      FROM users u
      WHERE ((u.email = (auth.jwt() ->> 'email')) AND (valentinesmessages.sender = u.id))
    )
  )
);

-- default is no reading if no time is set
CREATE POLICY "Recipient can read their messages after the release time."
ON "public"."valentinesmessages"
FOR SELECT
TO authenticated
USING (
  (EXISTS
	(SELECT setting_value FROM settings WHERE to_timestamp(setting_value) < now() AND name = 'valentines_deadline')
  )
  AND
  (EXISTS
    ( SELECT 1
      FROM users u
      WHERE ((u.email = (auth.jwt() ->> 'email')) AND (valentinesmessages.receiver = u.id))
    )
  )
);

-- "edits" should be implemented as DELETE/INSERT combos
CREATE POLICY "Sender can delete their own messages."
ON "public"."valentinesmessages"
FOR DELETE
TO authenticated
USING (
  (EXISTS
    ( SELECT 1
      FROM users u
      WHERE ((u.email = (auth.jwt() ->> 'email')) AND (valentinesmessages.sender = u.id))
    )
  )
);

CREATE POLICY "Sender can create valid messages."
ON "public"."valentinesmessages"
FOR INSERT
TO authenticated
WITH CHECK (
      sender = ( SELECT id
      FROM users u
      WHERE ((u.email = (auth.jwt() ->> 'email')))
      LIMIT 1
    ) AND verified_at IS NULL AND verified_by IS NULL
);


CREATE POLICY "Administrators can read and modify all messages."
ON "public"."valentinesmessages"
FOR ALL
TO authenticated
USING EXISTS
  ( SELECT 1
    FROM permissions
    WHERE ((permission = 'ADMIN' OR permission = 'VALENTINES')
      AND user_id = ( SELECT id FROM users u WHERE (u.email = (auth.jwt() ->> 'email')) LIMIT 1))
  )
);

GRANT INSERT,DELETE,SELECT ON valentinesmessages TO authenticated;
GRANT UPDATE(verified_at, verified_by) ON valentinesmessages TO authenticated;