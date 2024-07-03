CREATE TABLE attendance (
  id SERIAL PRIMARY KEY,
  organization_id INT NOT NULL,
  meeting_id INT NOT NULL,
  user_id INT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (meeting_id) REFERENCES meetings(id) on delete cascade,
  FOREIGN KEY (user_id) REFERENCES users(id) on delete cascade,
  FOREIGN KEY (organization_id) REFERENCES organizations(id) on delete cascade,
  CONSTRAINT no_duplicate_attendance UNIQUE(meeting_id, user_id)
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on attendance
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE attendance ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read access for own attendance"
ON public.attendance
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = public.attendance.user_id
    )
  )
);

CREATE POLICY "Enable insert access to active members of organization"
ON public.attendance
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND u.id = public.attendance.user_id
      AND m.organization_id = public.attendance.organization_id
      AND m.active = true
    )
  )
);

CREATE POLICY "Enable all access to organization admins"
ON public.attendance
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users as u
    INNER JOIN memberships as m ON (u.id = m.user_id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.organization_id = public.attendance.organization_id
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
      AND m.organization_id = public.attendance.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);

CREATE POLICY "Enable all access to site admins"
ON public.attendance
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
