CREATE TABLE backgroundtokens(
    /* Other columns */
    service TEXT,
    tokens TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on backgroundtokens
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE backgroundtokens ENABLE ROW LEVEL SECURITY;
