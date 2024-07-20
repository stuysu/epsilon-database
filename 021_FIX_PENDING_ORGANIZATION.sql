CREATE OR REPLACE FUNCTION user_has_pending_organization(user_email text)
RETURNS boolean AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM users AS u
    INNER JOIN memberships as m ON (m.user_id = u.id)
    INNER JOIN organizations as o ON (o.id = m.organization_id)
    WHERE (
      u.email = user_email
      AND m.role = 'CREATOR'
      AND o.state = 'PENDING'
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
