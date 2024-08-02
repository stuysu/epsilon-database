ALTER TABLE organizations DROP IF EXISTS benefit;
ALTER TABLE organizationedits DROP IF EXISTS benefit;

ALTER TABLE organizations ADD IF NOT EXISTS goals text;
ALTER TABLE organizationedits ADD IF NOT EXISTS goals text;

ALTER TABLE organizations ADD IF NOT EXISTS meeting_description text;
ALTER TABLE organizationedits ADD IF NOT EXISTS meeting_description text;

ALTER TABLE organizations ADD IF NOT EXISTS fair boolean;
ALTER TABLE organizationedits ADD IF NOT EXISTS fair boolean;
ALTER TABLE organizations ALTER fair SET DEFAULT false;
ALTER TABLE organizationedits ALTER fair SET DEFAULT false;
