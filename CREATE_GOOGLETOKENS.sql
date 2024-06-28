CREATE TABLE backgroundtokens(
    /* Other columns */
    service TEXT,
    tokens TEXT,
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

ALTER TABLE googletokens ENABLE ROW LEVEL SECURITY;
