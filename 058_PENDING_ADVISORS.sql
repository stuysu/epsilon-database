-- A club leader can name a faculty advisor who has no Epsilon account yet.
-- The invite is kept, site admins see it on Add User, and the teacher becomes
-- advisor as soon as their faculty account is created, the same way charter
-- advisors already are. Invites expire after a year.
-- Safe to re-run.

BEGIN;

CREATE TABLE IF NOT EXISTS public.pending_advisors (
  organization_id INT NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  email TEXT NOT NULL CHECK (email = lower(btrim(email))),
  invited_by INT REFERENCES users (id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, email)
);

CREATE INDEX IF NOT EXISTS pending_advisors_email_idx ON public.pending_advisors (email);

-- club leaders and site admins can see and cancel invites; only the
-- functions below add them
ALTER TABLE public.pending_advisors ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pending_advisors FROM PUBLIC, anon, authenticated;
GRANT SELECT, DELETE ON public.pending_advisors TO authenticated;

DROP POLICY IF EXISTS "Club leaders and site admins can read invites" ON public.pending_advisors;
CREATE POLICY "Club leaders and site admins can read invites"
ON public.pending_advisors
FOR SELECT
TO authenticated
USING (
  (SELECT public.caller_is_site_admin())
  OR organization_id IN (
    SELECT public.get_user_admin_organizations()
    UNION
    SELECT public.get_user_creator_organizations()
  )
);

DROP POLICY IF EXISTS "Club leaders and site admins can cancel invites" ON public.pending_advisors;
CREATE POLICY "Club leaders and site admins can cancel invites"
ON public.pending_advisors
FOR DELETE
TO authenticated
USING (
  (SELECT public.caller_is_site_admin())
  OR organization_id IN (
    SELECT public.get_user_admin_organizations()
    UNION
    SELECT public.get_user_creator_organizations()
  )
);

-- Same as 051, plus: the email is checked, and a teacher with no account is
-- invited instead. Returns added, already_advisor, already_leader,
-- not_faculty, invalid_email, invited, already_invited, too_many_invites or
-- club_not_approved. Only 'added' and 'invited' should be emailed.
CREATE OR REPLACE FUNCTION public.add_organization_advisor(org_id INT, advisor_email TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  wanted TEXT := lower(btrim(advisor_email, E' \t\r\n'));
  result TEXT;
  added INT;
BEGIN
  IF org_id NOT IN (
    SELECT public.get_user_admin_organizations()
    UNION
    SELECT public.get_user_creator_organizations()
  ) THEN
    RAISE EXCEPTION 'Only organization admins can add advisors.';
  END IF;

  -- ASCII only; kept in sync with EMAIL in the functions' _shared/advisorEmail.ts
  IF wanted !~ '^[a-z0-9._%+!#$&*/=?^{|}~-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' THEN
    RETURN 'invalid_email';
  END IF;

  -- one invite check per club at a time, and none while this teacher's
  -- account is being created (the trigger takes the same email lock)
  PERFORM pg_advisory_xact_lock(hashtext('pending_advisors_org'), org_id);
  PERFORM pg_advisory_xact_lock(hashtext('pending_advisors:' || wanted));

  result := make_organization_advisor(org_id, wanted);
  IF result <> 'no_account' THEN
    RETURN result;
  END IF;

  -- the charter's own advisor is added when the charter is approved
  IF (SELECT state FROM organizations WHERE id = org_id) IN ('PENDING', 'REJECTED') THEN
    RETURN 'club_not_approved';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pending_advisors
    WHERE organization_id = org_id AND email = wanted
      AND created_at > now() - interval '1 year'
  ) THEN
    RETURN 'already_invited';
  END IF;

  IF (
    SELECT count(*) FROM pending_advisors
    WHERE organization_id = org_id AND created_at > now() - interval '1 year'
  ) >= 3 THEN
    RETURN 'too_many_invites';
  END IF;

  -- an expired invite to the same email is renewed
  INSERT INTO pending_advisors (organization_id, email, invited_by)
  VALUES (
    org_id,
    wanted,
    (SELECT id FROM users WHERE email = lower(auth.jwt() ->> 'email'))
  )
  ON CONFLICT (organization_id, email) DO UPDATE
  SET created_at = now(), invited_by = EXCLUDED.invited_by
  WHERE pending_advisors.created_at <= now() - interval '1 year';
  GET DIAGNOSTICS added = ROW_COUNT;

  -- their account may have been created meanwhile
  IF EXISTS (SELECT 1 FROM users WHERE email = wanted) THEN
    DELETE FROM pending_advisors WHERE organization_id = org_id AND email = wanted;
    RETURN make_organization_advisor(org_id, wanted);
  END IF;

  RETURN CASE WHEN added > 0 THEN 'invited' ELSE 'already_invited' END;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.add_organization_advisor(INT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_organization_advisor(INT, TEXT) TO authenticated;

-- Same as 057, plus clubs that invited this email from their roster. Uses
-- invites from the last year for approved clubs, then clears those and any
-- expired ones.
CREATE OR REPLACE FUNCTION public.add_charter_advisor_for_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT NEW.is_faculty THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('pending_advisors:' || lower(trim(NEW.email))));

  PERFORM make_organization_advisor(organizations.id, NEW.email)
  FROM organizations
  WHERE organizations.state NOT IN ('PENDING', 'REJECTED')
    AND (
      lower(trim(organizations.faculty_email)) = lower(trim(NEW.email))
      OR EXISTS (
        SELECT 1 FROM pending_advisors
        WHERE pending_advisors.organization_id = organizations.id
          AND pending_advisors.email = lower(trim(NEW.email))
          AND pending_advisors.created_at > now() - interval '1 year'
      )
    );

  DELETE FROM pending_advisors
  USING organizations
  WHERE pending_advisors.email = lower(trim(NEW.email))
    AND organizations.id = pending_advisors.organization_id
    AND (
      organizations.state NOT IN ('PENDING', 'REJECTED')
      OR pending_advisors.created_at <= now() - interval '1 year'
    );

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.add_charter_advisor_for_user() FROM PUBLIC, anon, authenticated;

-- Emails to teachers with no account (roster invites and charter advisors)
-- go to any address, so they're limited: one per club and address every 30
-- days, and 5 per club a week. The functions ask before sending.
CREATE TABLE IF NOT EXISTS public.advisor_invite_emails (
  organization_id INT NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  sent_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS advisor_invite_emails_org_idx
  ON public.advisor_invite_emails (organization_id, sent_at);

ALTER TABLE public.advisor_invite_emails ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.advisor_invite_emails FROM PUBLIC, anon, authenticated;

-- 'send' (and records it), 'recent' (this address was emailed lately) or
-- 'limit' (the club hit its weekly limit)
CREATE OR REPLACE FUNCTION public.claim_advisor_invite_email(org_id INT, invitee TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  wanted TEXT := lower(btrim(invitee));
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('advisor_invite_emails'), org_id);

  DELETE FROM advisor_invite_emails WHERE sent_at <= now() - interval '30 days';

  IF EXISTS (
    SELECT 1 FROM advisor_invite_emails
    WHERE organization_id = org_id AND email = wanted
  ) THEN
    RETURN 'recent';
  END IF;

  IF (
    SELECT count(*) FROM advisor_invite_emails
    WHERE organization_id = org_id AND sent_at > now() - interval '7 days'
  ) >= 5 THEN
    RETURN 'limit';
  END IF;

  INSERT INTO advisor_invite_emails (organization_id, email) VALUES (org_id, wanted);
  RETURN 'send';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_advisor_invite_email(INT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_advisor_invite_email(INT, TEXT) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
