-- Fake data for a local database. Never run on production.
-- creator@example.com is a site admin and creates Test Club; student@ is a
-- member; outsider@ belongs to nothing.
INSERT INTO users
  (first_name, last_name, email, grad_year, is_faculty)
VALUES
  ('Casey', 'Creator', 'creator@example.com', 2027, false),
  ('Sam', 'Student', 'student@example.com', 2028, false),
  ('Fran', 'Faculty', 'faculty@example.com', NULL, true),
  ('Olly', 'Outsider', 'outsider@example.com', 2029, false);

INSERT INTO permissions
  (user_id, permission)
VALUES
  ((SELECT id FROM users WHERE email = 'creator@example.com'), 'ADMIN');

INSERT INTO organizations
  (name, url, state, mission, purpose)
VALUES
  ('Test Club', 'test-club', 'UNLOCKED', 'A club for testing.', 'Testing Epsilon locally.');

INSERT INTO memberships
  (organization_id, user_id, role, active)
VALUES
  (
    (SELECT id FROM organizations WHERE url = 'test-club'),
    (SELECT id FROM users WHERE email = 'creator@example.com'),
    'CREATOR',
    true
  ),
  (
    (SELECT id FROM organizations WHERE url = 'test-club'),
    (SELECT id FROM users WHERE email = 'student@example.com'),
    'MEMBER',
    true
  );

INSERT INTO rooms
  (name, floor)
VALUES
  ('303', 3),
  ('403', 4);

INSERT INTO meetings
  (organization_id, room_id, title, description, start_time, end_time)
VALUES
  (
    (SELECT id FROM organizations WHERE url = 'test-club'),
    (SELECT id FROM rooms WHERE name = '303'),
    'First meeting',
    'Our first meeting.',
    date_trunc('hour', now()) + interval '1 day',
    date_trunc('hour', now()) + interval '1 day 1 hour'
  );

INSERT INTO posts
  (organization_id, title, description)
VALUES
  (
    (SELECT id FROM organizations WHERE url = 'test-club'),
    'First post',
    'More posts are coming.'
  );
