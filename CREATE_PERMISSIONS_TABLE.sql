DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'site_perms') THEN
    DROP TYPE site_perms;
  END IF;

  CREATE TYPE site_perms AS ENUM ('ADMIN');
END $$;

CREATE TABLE permissions (
  id SERIAL PRIMARY KEY,
  user_id INT,
  permission site_perms,
  FOREIGN KEY (user_id) REFERENCES users(id),
  CONSTRAINT no_duplicate_permissions UNIQUE(user_id, permission),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on permissions
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
