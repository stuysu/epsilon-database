CREATE TABLE googlecalendars(
    id SERIAL PRIMARY KEY,
    org_url TEXT,
    calendar_id TEXT,
    FOREIGN KEY (org_url) REFERENCES organizations(url)
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on googlecalendars
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE googlecalendars ENABLE ROW LEVEL SECURITY;
