CREATE TABLE valentinesmessages (
  id INT PRIMARY KEY,
  sender INT NOT NULL,
  recipient INT NOT NULL,
  message TEXT NOT NULL,
  background VARCHAR(50) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  verified_at TIMESTAMP DEFAULT NULL,
  verified_by INT DEFAULT NULL,
  FOREIGN KEY (sender) REFERENCES users(id),
  FOREIGN KEY (recipient) REFERENCES users(id),
  FOREIGN KEY (verified_by) REFERENCES users(id)
);

ALTER TABLE valentinesmessages ENABLE ROW LEVEL SECURITY;

ALTER TYPE site_perms ADD VALUE 'VALENTINES';

-- 2025-02-14 00:00 EST, with seconds precision
INSERT INTO settings (name, setting_value) VALUES ('valentines_deadline', 1739509200);

CREATE POLICY "Sender can read their messages."
ON "public"."valentinesmessages"
FOR SELECT
TO authenticated
USING (
  (EXISTS
    ( SELECT 1
      FROM users u
      WHERE ((u.email = (jwt() ->> 'email'::text)) AND (valentinesmessages.sender = u.id))
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
      WHERE ((u.email = (jwt() ->> 'email'::text)) AND (valentinesmessages.recipient = u.id))
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
      WHERE ((u.email = (jwt() ->> 'email'::text)) AND (valentinesmessages.sender = u.id))
    )
  )
);

CREATE POLICY "Sender can create valid messages."
ON "public"."valentinesmessages"
FOR INSERT
TO authenticated
USING (
	sender = ( SELECT id
      FROM users u
      WHERE ((u.email = (jwt() ->> 'email'::text)))
	LIMIT 1;
    ) AND verified_at = NULL AND verified_by = NULL
);


CREATE POLICY "Administrators can read and modify all unapproved messages."
ON "public"."valentinesmessages"
FOR ALL
TO authenticated
USING (
  (verified_at = NULL OR verified_by = NULL OR verified_at < updated_at)
  AND
  (EXISTS
    ( SELECT 1
      FROM permissions
      WHERE ((permission = 'ADMIN' OR permission = 'VALENTINES')
        AND user_id = ( SELECT id FROM users u WHERE (u.email = (jwt() ->> 'email'::text))))
    )
  )
);
