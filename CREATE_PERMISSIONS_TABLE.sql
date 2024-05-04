DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'site_perms') THEN
    DROP TYPE site_perms;
  END IF;

  CREATE TYPE site_perms AS ENUM ('ADMIN');
END $$;

CREATE TABLE permissions (
  id SERIAL PRIMARY KEY,
  user_id INT NOT NULL,
  permission site_perms NOT NULL,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id),
  CONSTRAINT no_duplicate_permissions UNIQUE(user_id, permission)
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on permissions
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read access to anyone with permissions"
ON public.permissions
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = user_id
    )
  )
);

CREATE POLICY "Enable all access to site admins"
ON public.permissions
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = user_id
      AND permission = 'ADMIN'
    )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = user_id
      AND permission = 'ADMIN'
    )
  )
);


