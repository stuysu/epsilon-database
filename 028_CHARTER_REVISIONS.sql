ALTER TABLE settings DROP CONSTRAINT CK_T1_Locked RESTRICT;
ALTER TABLE settings DROP COLUMN Lock;
ALTER TABLE settings ADD COLUMN name VARCHAR PRIMARY KEY DEFAULT 'required_members';  -- maintains compatibility with 023
ALTER TABLE settings RENAME COLUMN required_members TO setting_value;
ALTER TABLE settings ALTER COLUMN setting_value TYPE bigint; -- for timestamps
-- add default
INSERT INTO settings (name, setting_value) VALUES ('charter_deadline', 0);  -- no deadline

ALTER TABLE organizations ADD IF NOT EXISTS faculty_email VARCHAR;
ALTER TABLE organizationedits ADD IF NOT EXISTS faculty_email VARCHAR;
