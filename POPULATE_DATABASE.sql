-- populate database with fake data
INSERT INTO organizations (name, url, state)
VALUES('SUIT', 'suit', 'ADMIN');

INSERT INTO users
  (first_name, last_name, email, grad_year)
VALUES
  ('Randy', 'Sim', 'rsim40@stuy.edu', 2024),
  ('IT', 'Department', 'itdepartment@stuysu.org', 2023);

INSERT INTO rooms
  (name, floor)
VALUES
  ('303', 3),
  ('403', 3);

INSERT INTO memberships 
  (organization_id, user_id, role, active)
VALUES
  (
    (SELECT id FROM users WHERE email='rsim40@stuy.edu'),
    (SELECT id FROM organizations WHERE name='SUIT'),
    'CREATOR',
    true
  );

INSERT INTO meetings 
  (organization_id, room_id, title, description, start_time, end_time)
VALUES
  (
    (SELECT id FROM organizations WHERE name='SUIT'),
    (SELECT id FROM rooms WHERE name='303'),
    'First meeting guys!',
    'This is our first meeting, I hope you will come',
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
  );

INSERT INTO permissions 
  (user_id, permission)
VALUES
  (
    (SELECT id FROM users WHERE email='rsim40@stuy.edu'),
    'ADMIN'
  );

INSERT INTO posts
  (organization_id, title, description)
VALUES
  (
    (SELECT id FROM organizations WHERE name='SUIT'),
    'First post!',
    'This is our first post just letting yall know that more are coming!'
  );
