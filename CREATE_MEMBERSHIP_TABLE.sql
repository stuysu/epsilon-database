DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'org_role') THEN
    DROP TYPE org_role;
  END IF;

  CREATE TYPE org_role AS ENUM ('MEMBER', 'ADVISOR', 'ADMIN', 'CREATOR');
END $$;

CREATE TABLE memberships (
  id SERIAL PRIMARY KEY,
  organization_id INT,
  user_id INT,
  role org_role DEFAULT 'MEMBER',
  role_name VARCHAR(255),
  active BOOLEAN DEFAULT false,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (organization_id) REFERENCES organizations(id),
  FOREIGN KEY (user_id) REFERENCES users(id),
  CONSTRAINT no_duplicate_joins UNIQUE(organization_id, user_id)
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on memberships
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read access to authenticated users only"
ON public.memberships
FOR SELECT
TO authenticated
USING (
  EXISTS ( 
    SELECT 1
    FROM users AS u
    WHERE (u.email = (auth.jwt() ->> 'email'))
  )
);

CREATE POLICY "Enable pending membership creation to authenticated users"
ON public.memberships
FOR INSERT
TO authenticated
WITH CHECK(
  (EXISTS ( 
    SELECT 1
    FROM users AS u
    WHERE (
      (u.email = (auth.jwt() ->> 'email')) 
      AND (user_id = u.id)
    )
  )) 
  AND (EXISTS ( 
    SELECT 1
    FROM organizations AS o
    WHERE (o.id = organization_id)
  )) 
  AND (active = false) 
  AND (role = 'MEMBER') 
  AND (role_name = NULL)
);

CREATE POLICY "Enable members except creator to delete their own memberships"
ON public.memberships
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users as u
    WHERE (
      (u.email = (auth.jwt() ->> 'email'))
      AND (memberships.user_id = u.id)
    )
  )
  AND (memberships.role != 'CREATOR')
);

CREATE POLICY "Enable regular membership update access to organization admins only"
ON public.memberships
FOR UPDATE
TO authenticated
WITH CHECK(
  EXISTS ( 
    SELECT 1
    FROM users AS u
    INNER JOIN memberships AS m ON ((m.user_id = u.id))
    WHERE (
      (m.organization_id = memberships.organization_id)
      AND (m.role = 'ADMIN') 
      AND (u.email = (auth.jwt() ->> 'email'))
      AND (m.id = memberships.id)
      AND (memberships.role != 'ADMIN')
      AND (memberships.role != 'CREATOR')
    )
  )
);

CREATE POLICY "Enable regular membership delete access to organization admins only"
ON public.memberships
FOR DELETE
TO authenticated
USING (
  EXISTS ( 
    SELECT 1
    FROM users AS u
    INNER JOIN memberships AS m ON ((m.user_id = u.id))
    WHERE (
      (m.organization_id = memberships.organization_id)
      AND (m.role = 'ADMIN') 
      AND (u.email = (auth.jwt() ->> 'email'))
      AND (m.id = memberships.id)
      AND (memberships.role != 'ADMIN')
      AND (memberships.role != 'CREATOR')
    )
  )
);

CREATE POLICY "Enable all membership update access to organization creator only"
ON public.memberships
FOR UPDATE
TO authenticated
WITH CHECK(
  EXISTS ( 
    SELECT 1
    FROM users AS u
    INNER JOIN memberships AS m ON ((m.user_id = u.id))
    WHERE (
      (m.organization_id = memberships.organization_id)
      AND (m.role = 'CREATOR') 
      AND (u.email = (auth.jwt() ->> 'email'))
      AND (m.id = memberships.id)
    )
  )
);

CREATE POLICY "Enable all membership delete access to organization creator only"
ON public.memberships
FOR DELETE
TO authenticated
USING (
  EXISTS ( 
    SELECT 1
    FROM users AS u
    INNER JOIN memberships AS m ON ((m.user_id = u.id))
    WHERE (
      (m.organization_id = memberships.organization_id)
      AND (m.role = 'CREATOR') 
      AND (u.email = (auth.jwt() ->> 'email'))
      AND (m.id = memberships.id)
      AND (memberships.role != 'CREATOR') -- can't kick creators out
    )
  )
);
