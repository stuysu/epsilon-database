-- Makes the membership insert policy respect organizations.joinable and state.
-- The policy only checked that the organization existed, so anyone could insert
-- a join request straight through PostgREST for a club that turned joining off,
-- or for a PENDING or PUNISHED club. The join-organization function inserts with
-- the user's JWT, so this policy is what actually gates joining. LOCKED clubs stay
-- joinable on purpose: approved clubs start LOCKED and unlock once enough members
-- have been approved. Creator memberships (create-organization) and accepted
-- invites (accept-invite) are inserted with the service role and are not affected.
DROP POLICY IF EXISTS "Enable pending membership creation to authenticated users" ON public.memberships;

CREATE POLICY "Enable pending membership creation to authenticated users"
ON public.memberships
FOR INSERT
TO authenticated
WITH CHECK (
  (EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (
      (u.email = (auth.jwt() ->> 'email'))
      AND (user_id = u.id)
    )
  ))
  AND (EXISTS (
    SELECT 1
    FROM organizations AS o
    WHERE (
      (o.id = organization_id)
      AND (o.joinable IS TRUE)
      AND (o.state NOT IN ('PENDING', 'PUNISHED'))
    )
  ))
  AND (active = false)
  AND (role = 'MEMBER')
  AND (role_name IS NULL)
);
