CREATE TABLE googlecalendarevents(
    id SERIAL PRIMARY KEY,
    calendar_id int,
    event_id TEXT,
    meeting_id int,
    FOREIGN KEY (calendar_id) REFERENCES googlecalendars(id),
    FOREIGN KEY (meeting_id) REFERENCES meetings(id)
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on googlecalendarevents
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE googlecalendarevents ENABLE ROW LEVEL SECURITY;
