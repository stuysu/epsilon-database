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
  name TEXT UNIQUE NOT NULL,
  url TEXT UNIQUE NOT NULL,
  socials TEXT NULL,
  picture TEXT NULL,
  mission TEXT NULL,
  purpose TEXT NULL,
  benefit TEXT NULL,
  appointment_procedures TEXT NULL,
  uniqueness TEXT NULL,
  meeting_schedule TEXT NULL,
  meeting_days TEXT[] NULL,
  keywords TEXT NULL, -- keywords is text. search is compared to keywords with ilike pattern
  tags TEXT[] NULL,
  commitment_level org_commitment DEFAULT 'NONE',
  is_returning BOOLEAN DEFAULT false,
  returning_info TEXT NULL,
  state org_state DEFAULT 'PENDING',
  joinable BOOLEAN DEFAULT true,
  join_instructions TEXT NULL,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
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
