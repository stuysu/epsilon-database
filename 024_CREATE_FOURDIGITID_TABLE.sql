CREATE TABLE IF NOT EXISTS fourdigitids (
  user_id integer NOT NULL UNIQUE,
  PRIMARY KEY (user_id),
  FOREIGN KEY (user_id) REFERENCES users(id) on delete cascade,
  value smallint UNIQUE
);

ALTER TABLE fourdigitids ENABLE row level security;

CREATE POLICY "Users can view their own four digit IDs."
ON "public"."fourdigitids"
FOR SELECT
TO authenticated
USING (
  (EXISTS
    ( SELECT 1
      FROM users u
      WHERE ((u.email = (auth.jwt() ->> 'email'::text)) AND (fourdigitids.user_id = u.id))
    )
  )
);
