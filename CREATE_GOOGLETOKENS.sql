CREATE TABLE googletokens(
    Lock char(1) not null DEFAULT 'X', -- make this column contain only 1 value, but also be unique to create only 1 row
    /* Other columns */
    refresh TEXT DEFAULT null,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    /* constraints */
    constraint PK_T2 PRIMARY KEY (Lock),
    constraint CK_T2_Locked CHECK (Lock='X')
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
create trigger handle_updated_at before update on googletokens
  for each row execute procedure moddatetime (updated_at);

ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
