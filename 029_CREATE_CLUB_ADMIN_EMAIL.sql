CREATE VIEW clubadmins AS
SELECT
  m.organization_id,
  m.user_id,
  u.email
FROM
  memberships m
JOIN
  users u
ON
  m.user_id = u.id
WHERE
  m.role IN ('ADMIN', 'CREATOR');
