/* NULL means no update, admin client can skip over fields with value of null */
/* if organizationEdit for org exists, then any updated fields will update that organizationEdit, else a new one is created */
CREATE TABLE organizationedits (
  id SERIAL PRIMARY KEY,
  organization_id INT UNIQUE NOT NULL,
  name VARCHAR(255) UNIQUE NULL,
  url VARCHAR(255) UNIQUE NULL,
  picture VARCHAR(255) NULL,
  mission TEXT NULL,
  purpose TEXT NULL,
  benefit TEXT NULL,
  appointment_procedures TEXT NULL,
  uniqueness TEXT NULL,
  meeting_schedule TEXT NULL,
  meeting_days VARCHAR(255) NULL,
  commitment_level org_commitment NULL,
  keywords TEXT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (organization_id) REFERENCES organizations(id)
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on organizationEdits
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE organizationedits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow organization admins all access to their organizationedits"
ON public.organizationedits
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM memberships as m
    INNER JOIN users as u ON (m.user_id = u.id)
    WHERE(
      u.email = auth.jwt() ->> 'email'
      AND organization_id = m.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM memberships as m
    INNER JOIN users as u ON (m.user_id = u.id)
    WHERE(
      u.email = auth.jwt() ->> 'email'
      AND organization_id = m.organization_id
      AND (m.role = 'ADMIN' OR m.role = 'CREATOR')
    )
  )
);

CREATE POLICY "Enable all access to site admins"
ON public.organizationedits
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
