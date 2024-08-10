-- approve-member will fail to find a `required_members` value and crash if there is no row of default values given.

INSERT INTO settings DEFAULT VALUES;
