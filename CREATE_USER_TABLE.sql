CREATE TABLE users (
  -- UUID PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  id SERIAL PRIMARY KEY,
  first_name VARCHAR(255) NOT NULL,
  last_name VARCHAR(255) NOT NULL,
  email TEXT UNIQUE, -- REFERENCES auth.users(email) ON DELETE CASCADE <- supabase doesn't support this
  grad_year INT NULL,
  picture VARCHAR(255) NULL, -- server should generate a default pfp
  is_faculty BOOLEAN DEFAULT false,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on users
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE users ENABLE ROW LEVEL SECURITY;

/*
create or replace function auth.email() returns text as $$
  select nullif(current_setting('request.jwt.claim.email', true), '')::text;
$$ language sql;
*/

-- POLICIES
CREATE POLICY "Enable read access to authenticated users only"
ON public.users
FOR SELECT 
TO authenticated
USING (
  email = auth.jwt() ->> 'email'
);
