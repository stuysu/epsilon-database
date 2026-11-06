-- Recipients could read their valentines straight from the table, which let
-- them select the sender column (or embed the sender's user row) even when the
-- sender asked to stay anonymous, and also read messages that had not been
-- approved yet.
--
-- Recipients now lose direct access to the table and read their valentines
-- through get_received_valentines() instead. It only returns approved
-- messages, only after the valentines_deadline setting has passed, and only
-- includes the sender when show_sender is true.
--
-- Not changed: senders still read and delete their own messages, and ADMIN and
-- VALENTINES moderators still read and modify every message. Safe to run more
-- than once.
DROP POLICY IF EXISTS "Recipient can read their messages after the release time."
ON public.valentinesmessages;

-- TRUNCATE ignores row level security, so nobody outside the backend needs it.
REVOKE TRUNCATE ON public.valentinesmessages FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_received_valentines()
RETURNS TABLE (
  id INT,
  sender INT,
  receiver INT,
  show_sender BOOLEAN,
  message TEXT,
  background VARCHAR,
  verified_at TIMESTAMP
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    v.id,
    CASE WHEN v.show_sender THEN v.sender END,
    v.receiver,
    v.show_sender,
    v.message,
    v.background,
    v.verified_at
  FROM public.valentinesmessages AS v
  INNER JOIN public.users AS u ON (u.id = v.receiver)
  WHERE u.email = (auth.jwt() ->> 'email')
    AND v.verified_at IS NOT NULL
    AND v.verified_by IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.settings AS s
      WHERE s.name = 'valentines_deadline'
        AND to_timestamp(s.setting_value::double precision) < now()
    )
  ORDER BY v.verified_at, v.id;
$$;

REVOKE ALL ON FUNCTION public.get_received_valentines() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_received_valentines() TO authenticated;

NOTIFY pgrst, 'reload schema';
