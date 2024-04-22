CREATE TABLE users (
  -- UUID PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  id SERIAL PRIMARY KEY,
  first_name VARCHAR(255) NOT NULL,
  last_name VARCHAR(255) NOT NULL,
  email TEXT UNIQUE NOT NULL, -- REFERENCES auth.users(email) ON DELETE CASCADE <- supabase doesn't support this
  grad_year INT NULL,
  picture VARCHAR(255) NULL, -- server should generate a default pfp
  is_faculty BOOLEAN DEFAULT false NOT NULL,
  active BOOLEAN DEFAULT true NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on users
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- POLICIES
CREATE POLICY "Enable read access to authenticated users only"
ON public.users
FOR SELECT 
TO authenticated
USING (true);

CREATE OR REPLACE FUNCTION public.is_admin(u_id INT)
RETURNS BOOLEAN 
LANGUAGE plpgsql
SECURITY definer
SET search_path = public
stable
AS $$
BEGIN
  PERFORM
  FROM public.permissions
  WHERE (
    user_id = u_id
    AND permission = 'ADMIN'
  );
  RETURN FOUND;
END;
$$;

CREATE POLICY "Enable all access to site admins"
ON public.users
FOR ALL
TO authenticated
USING (
  public.is_admin(id)
)
WITH CHECK (
  public.is_admin(id)
);
