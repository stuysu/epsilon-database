CREATE TABLE posts (
  id SERIAL PRIMARY KEY,
  organization_id INT NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (organization_id) REFERENCES organizations(id) on delete cascade
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on posts
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE posts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read access to authenticated users only"
ON public.posts
FOR SELECT
TO authenticated
USING (
  EXISTS ( 
    SELECT 1
    FROM users AS u
    WHERE (u.email = (auth.jwt() ->> 'email'))
  )
);

CREATE POLICY "Enable all access to organization admins only"
ON public.posts
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships as m ON (m.user_id = u.id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND (m.role = 'CREATOR' OR m.role = 'ADMIN')
      AND (m.organization_id = public.posts.organization_id)
    )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships as m ON (m.user_id = u.id)
    WHERE (
      u.email = (auth.jwt() ->> 'email')
      AND (m.role = 'CREATOR' OR m.role = 'ADMIN')
      AND (m.organization_id = public.posts.organization_id)
    )
  )
);
