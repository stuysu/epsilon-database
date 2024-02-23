DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'org_state') THEN
    DROP TYPE org_state;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'org_commitment') THEN
    DROP TYPE org_commitment;
  END IF;

  CREATE TYPE org_state AS ENUM ('PENDING', 'LOCKED', 'UNLOCKED', 'ADMIN');
  CREATE TYPE org_commitment AS ENUM ('NONE', 'LOW', 'MEDIUM', 'HIGH');
END $$;

-- PENDING: waiting for approval
-- LOCKED: approved, but requirements are not satisfied yet
-- UNLOCKED: approved and requirements are satisfied
-- ADMIN: bypasses all requirements

-- create organizations table
CREATE TABLE organizations (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) UNIQUE NOT NULL,
  url VARCHAR(255) UNIQUE NOT NULL,
  picture VARCHAR(255) NULL,
  mission TEXT NULL,
  purpose TEXT NULL,
  benefit TEXT NULL,
  appointment_procedures TEXT NULL,
  uniqueness TEXT NULL,
  meeting_schedule TEXT NULL,
  meeting_days VARCHAR(255) NULL,
  commitment_level org_commitment DEFAULT 'NONE',
  state org_state DEFAULT 'PENDING',
  joinable BOOLEAN DEFAULT true,
  join_instructions TEXT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on organizations
  for each row execute procedure moddatetime (updated_at);

-- should always enable RLS for every table, even if it is public. This gives full control to policies.
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;

-- POLICIES

CREATE POLICY "Enable read access to everyone"
ON public.organizations
FOR SELECT USING (
  true
);

CREATE POLICY "Allow authenticated users to create pending organizations"
ON public.organizations
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (u.email = (auth.jwt() ->> 'email'))
  )
  AND state = 'PENDING'
);

CREATE POLICY "Allow authenticated users to update pending organizations"
ON public.organizations
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships as m ON (m.user_id = u.id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.role = 'CREATOR'
      AND organizations.id = m.organization_id
    )
  )
  AND state = 'PENDING'
);

CREATE POLICY "Allow authenticated users to delete their own organization"
ON public.organizations
USING (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships as m ON (m.user_id = u.id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND m.role = 'CREATOR'
      AND organizations.id = m.organization_id
    )
  )
);
