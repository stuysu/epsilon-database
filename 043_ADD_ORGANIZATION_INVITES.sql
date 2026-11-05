-- Lets organization admins invite people who already have an Epsilon account.
-- Invites are shown to the invited person inside the site (no emails), and an
-- accepted invite skips the join request approval step. Invites are created
-- through create_organization_invites, accepted through the accept-invite edge
-- function and declined through decline_organization_invite. Answered invites
-- are kept so they still count toward the daily limit; admins can cancel
-- pending ones.
CREATE TABLE IF NOT EXISTS organization_invites (
  id SERIAL PRIMARY KEY,
  organization_id INT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invited_by INT REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
  CONSTRAINT one_invite_per_user UNIQUE (organization_id, user_id)
);

ALTER TABLE organization_invites ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON organization_invites FROM anon, authenticated;
GRANT SELECT, DELETE ON organization_invites TO authenticated;

CREATE POLICY "Enable organization admins and invited users to view invites"
  ON organization_invites FOR SELECT TO authenticated
  USING (
    organization_invites.user_id IN (
      SELECT users.id FROM users WHERE users.email = (auth.jwt() ->> 'email')
    )
    OR
    organization_invites.organization_id IN (
      SELECT public.get_user_admin_organizations()
      UNION
      SELECT public.get_user_creator_organizations()
    )
  );

CREATE POLICY "Enable organization admins to cancel pending invites"
  ON organization_invites FOR DELETE TO authenticated
  USING (
    organization_invites.status = 'pending'
    AND
    organization_invites.organization_id IN (
      SELECT public.get_user_admin_organizations()
      UNION
      SELECT public.get_user_creator_organizations()
    )
  );

-- How many invites one organization can send per day. Change the value in the
-- settings table to adjust it.
INSERT INTO settings (name, setting_value, visible)
VALUES ('max_daily_invites', 50, false)
ON CONFLICT (name) DO NOTHING;

-- Invites a list of people by email. Returns one result per email with a
-- status of invited, already_invited, already_member, no_account, invalid or
-- limit_reached (the organization used up today's invites).
CREATE OR REPLACE FUNCTION public.create_organization_invites(org_id INT, emails TEXT[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  inviter_id INT;
  clean_email TEXT;
  invitee_id INT;
  results JSONB := '[]'::jsonb;
  status TEXT;
  daily_limit INT := coalesce(
    (SELECT setting_value FROM settings WHERE name = 'max_daily_invites'),
    50
  );
  sent_today INT := (
    SELECT count(*)
    FROM organization_invites
    WHERE (
      organization_invites.organization_id = org_id
      AND organization_invites.created_at > now() - INTERVAL '1 day'
    )
  );
BEGIN
  IF org_id NOT IN (
    SELECT public.get_user_admin_organizations()
    UNION
    SELECT public.get_user_creator_organizations()
  ) THEN
    RAISE EXCEPTION 'Only organization admins can invite members.';
  END IF;

  SELECT users.id INTO inviter_id FROM users WHERE users.email = (auth.jwt() ->> 'email');

  -- each email once, in the order they were entered
  FOR clean_email IN
    SELECT lower(trim(email))
    FROM unnest(emails) WITH ORDINALITY AS entered (email, entered_order)
    WHERE trim(email) <> ''
    GROUP BY lower(trim(email))
    ORDER BY min(entered_order)
  LOOP
    invitee_id := NULL;
    IF clean_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
      status := 'invalid';
    ELSE
      SELECT users.id INTO invitee_id FROM users WHERE lower(users.email) = clean_email;

      IF invitee_id IS NULL THEN
        status := 'no_account';
      ELSIF EXISTS (
        SELECT 1 FROM memberships
        WHERE (
          memberships.organization_id = org_id
          AND memberships.user_id = invitee_id
          AND memberships.active = true
        )
      ) THEN
        status := 'already_member';
      ELSIF EXISTS (
        SELECT 1 FROM organization_invites
        WHERE (
          organization_invites.organization_id = org_id
          AND organization_invites.user_id = invitee_id
          AND organization_invites.status = 'pending'
        )
      ) THEN
        status := 'already_invited';
      ELSIF sent_today >= daily_limit THEN
        status := 'limit_reached';
      ELSE
        -- someone who declined or left can be invited again
        INSERT INTO organization_invites (organization_id, user_id, invited_by)
        VALUES (org_id, invitee_id, inviter_id)
        ON CONFLICT ON CONSTRAINT one_invite_per_user DO UPDATE
        SET status = 'pending', invited_by = inviter_id, created_at = now();
        sent_today := sent_today + 1;
        status := 'invited';
      END IF;
    END IF;

    results := results || jsonb_build_object('email', clean_email, 'status', status);
  END LOOP;

  RETURN results;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_organization_invites TO authenticated;
REVOKE EXECUTE ON FUNCTION public.create_organization_invites(INT, TEXT[]) FROM PUBLIC, anon;

-- Lets the invited person decline one of their pending invites.
CREATE OR REPLACE FUNCTION public.decline_organization_invite(invite_id INT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE organization_invites
  SET status = 'declined'
  FROM users
  WHERE (
    organization_invites.id = invite_id
    AND organization_invites.status = 'pending'
    AND users.id = organization_invites.user_id
    AND users.email = (auth.jwt() ->> 'email')
  );
$$;

GRANT EXECUTE ON FUNCTION public.decline_organization_invite TO authenticated;
REVOKE EXECUTE ON FUNCTION public.decline_organization_invite(INT) FROM PUBLIC, anon;

NOTIFY pgrst, 'reload schema';
