CREATE TABLE orgmessages (
  id SERIAL PRIMARY KEY,
  organization_id INT NOT NULL,
  user_id INT NOT NULL,
  content TEXT,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (organization_id) REFERENCES organizations(id) on delete cascade,
  FOREIGN KEY (user_id) REFERENCES users(id) on delete cascade
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on orgmessages
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE orgmessages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read for org admins"
ON public.orgmessages
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = public.orgmessages.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);

CREATE POLICY "Enable delete for org admin own message"
ON public.orgmessages
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = user_id
      AND m.organization_id = public.orgmessages.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);

CREATE POLICY "Enable update for org admin own message"
ON public.orgmessages
FOR UPDATE
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = user_id
      AND m.organization_id = public.orgmessages.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);

CREATE POLICY "Enable insert for org admin own message"
ON public.orgmessages
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = user_id
      AND m.organization_id = public.orgmessages.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);


CREATE POLICY "Enable all access to site admins"
ON public.orgmessages
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM permissions as p
    INNER JOIN users as u ON (p.user_id = u.id)
    WHERE (
      u.email = auth.jwt() ->> 'email'
      AND ( -- roles here
        p.permission = 'ADMIN'
      )
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
      AND ( -- roles here
        p.permission = 'ADMIN'
      )
    )
  )
);

