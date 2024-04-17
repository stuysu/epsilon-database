CREATE TABLE meetings (
  id SERIAL PRIMARY KEY,
  organization_id INT NOT NULL,
  room_id INT, /* KEEP THIS NULLABLE, NULL = VIRTUAL ROOMS */
  is_public BOOLEAN DEFAULT true NOT NULL,
  title VARCHAR(500) NOT NULL,
  description TEXT NOT NULL,
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (organization_id) REFERENCES organizations(id) on delete cascade,
  FOREIGN KEY(room_id) REFERENCES rooms(id)
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on meetings
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE meetings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read access of public meetings to authenticated users"
ON public.meetings
FOR SELECT
TO authenticated
USING (
  EXISTS ( 
    SELECT 1
    FROM users AS u
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND is_public = true
    )
  )
);

CREATE POLICY "Enable read access of all organization meetings to organization members"
ON public.meetings
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = organization_id
    )
  )
);

CREATE POLICY "Enable insert access to admins of organization"
ON public.meetings
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);

CREATE POLICY "Enable delete access to admins of organization"
ON public.meetings
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);

CREATE POLICY "Enable update access to admins of organization"
ON public.meetings
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);

CREATE POLICY "Enable all access to site admins"
ON public.meetings
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

