-- List of rooms that are available for use
CREATE TABLE rooms (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) UNIQUE NOT NULL,
  floor INT NULL,
  approval_required BOOLEAN DEFAULT false,
  available_days VARCHAR(255) DEFAULT 'MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY',
  comments TEXT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on rooms
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable read access to all authenticated users"
ON public.rooms
FOR SELECT
TO authenticated
USING (
  EXISTS ( 
    SELECT 1
    FROM users AS u
    WHERE (u.email = (auth.jwt() ->> 'email'))
  )
);

CREATE POLICY "Enable all access to site admins"
ON public.rooms
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
);
