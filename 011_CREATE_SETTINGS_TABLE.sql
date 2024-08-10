-- one row MUST be present in `settings` to ensure proper operation -- see `023_ADD_DEFAULT_SETTING.sql`
CREATE TABLE settings(
    Lock char(1) not null DEFAULT 'X', -- make this column contain only 1 value, but also be unique to create only 1 row
    /* Other columns */
    required_members INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    /* constraints */
    constraint PK_T1 PRIMARY KEY (Lock),
    constraint CK_T1_Locked CHECK (Lock='X')
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on settings
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable all access to site admins"
ON public.settings
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
