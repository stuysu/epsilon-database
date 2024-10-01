CREATE TABLE IF NOT EXISTS membershipnotifications (
  membership_id integer NOT NULL UNIQUE,
  PRIMARY KEY (membership_id),
  FOREIGN KEY (membership_id) REFERENCES memberships(id) on delete cascade,
  allow_notifications boolean DEFAULT TRUE
);

INSERT INTO membershipnotifications (membership_id, allow_notifications)
SELECT id, allow_notifications
FROM memberships;

ALTER TABLE memberships
DROP COLUMN allow_notifications;
