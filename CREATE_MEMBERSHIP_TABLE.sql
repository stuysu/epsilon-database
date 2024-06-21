DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'org_role') THEN
    DROP TYPE org_role;
  END IF;

  CREATE TYPE org_role AS ENUM ('MEMBER', 'ADVISOR', 'ADMIN', 'CREATOR');
END $$;

CREATE TABLE memberships (
  id SERIAL PRIMARY KEY,
  organization_id INT NOT NULL,
  user_id INT NOT NULL,
  join_message TEXT,
  allow_notifications BOOL DEFAULT true,
  role org_role DEFAULT 'MEMBER' NOT NULL,
  role_name VARCHAR(255),
  active BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (organization_id) REFERENCES organizations(id) on delete cascade,
  FOREIGN KEY (user_id) REFERENCES users(id) on delete cascade,
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
    WHERE (
      o.id = public.memberships.organization_id
    )
  ))
  AND (public.memberships.active = false) 
  AND (public.memberships.role = 'MEMBER') 
  AND (public.memberships.role_name IS NULL)
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
      AND (public.memberships.user_id = u.id)
    )
  )
  AND (role != 'CREATOR')
);

CREATE OR REPLACE FUNCTION public.get_user_admin_organizations()
RETURNS SETOF INT
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
stable
AS $$
  SELECT organization_id
  FROM memberships
  INNER JOIN users ON (memberships.user_id = users.id)
  WHERE (
    (users.email = auth.jwt() ->> 'email')
    AND (memberships.role = 'ADMIN')
  )
$$;

CREATE OR REPLACE FUNCTION public.get_user_creator_organizations()
RETURNS SETOF INT
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
stable
AS $$
  SELECT organization_id
  FROM memberships
  INNER JOIN users ON (memberships.user_id = users.id)
  WHERE (
    (users.email = auth.jwt() ->> 'email')
    AND (memberships.role = 'CREATOR')
  )
$$;

CREATE POLICY "Enable regular membership update access to organization admins only"
ON public.memberships
FOR UPDATE
TO authenticated
USING (
  public.memberships.organization_id IN (
    SELECT public.get_user_admin_organizations()
  )
  AND role != 'ADMIN'
  AND role != 'CREATOR'
)
WITH CHECK(
  public.memberships.organization_id IN (
    SELECT public.get_user_admin_organizations()
  )
  AND role != 'ADMIN'
  AND role != 'CREATOR'
);

CREATE POLICY "Enable regular membership delete access to organization admins only"
ON public.memberships
FOR DELETE
TO authenticated
USING (
  public.memberships.organization_id IN (
    SELECT public.get_user_admin_organizations()
  )
  AND role != 'ADMIN'
  AND role != 'CREATOR'
);

CREATE POLICY "Enable all membership update access to organization creator only"
ON public.memberships
FOR UPDATE
TO authenticated
USING (
  public.memberships.organization_id IN (
    SELECT public.get_user_creator_organizations()
  )
)
WITH CHECK (
  public.memberships.organization_id IN (
    SELECT public.get_user_creator_organizations()
  )
);

CREATE POLICY "Enable all membership delete access to organization creator only"
ON public.memberships
FOR DELETE
TO authenticated
USING (
  public.memberships.organization_id IN (
    SELECT public.get_user_creator_organizations()
  )
  AND role != 'CREATOR'
);
