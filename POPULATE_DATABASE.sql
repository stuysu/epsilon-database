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
