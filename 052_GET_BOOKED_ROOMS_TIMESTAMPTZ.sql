-- get_booked_rooms took `timestamp without time zone` arguments. Postgres
-- drops any UTC offset when parsing into that type, then converts back using
-- the session TimeZone when comparing against meetings.start_time/end_time
-- (both timestamptz). So '2026-11-10T21:30:00-05:00' was treated as 21:30 UTC,
-- and the 'Z' strings the frontend sends were only correct while the session
-- TimeZone was UTC.
--
-- Take timestamptz instead so the offset is kept and the session TimeZone no
-- longer matters for offset-bearing input. Results for the current callers
-- (ISO 'Z' strings over PostgREST, whose session is UTC) are unchanged.
-- The old overload is dropped so PostgREST cannot pick between two functions.
-- Return shape, body, security and grants are the same as before.

BEGIN;

DROP FUNCTION IF EXISTS public.get_booked_rooms(timestamp without time zone, timestamp without time zone);

CREATE OR REPLACE FUNCTION public.get_booked_rooms(meeting_start timestamptz, meeting_end timestamptz)
RETURNS TABLE (room_id INT, meeting_id INT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT r.id, m.id
  FROM rooms AS r
  INNER JOIN meetings AS m ON (m.room_id = r.id)
  WHERE (
    (
      meeting_start >= start_time and
      meeting_start <= end_time
    ) or
    (
      meeting_end >= start_time and
      meeting_end <= end_time
    ) or
    (
      start_time >= meeting_start and
      start_time <= meeting_end
    ) or
    (
      end_time >= meeting_start and
      end_time <= meeting_end
    )
  )
$$;

-- same grants the old function had on prod (PUBLIC, anon, authenticated, service_role)
GRANT EXECUTE ON FUNCTION public.get_booked_rooms(timestamptz, timestamptz) TO PUBLIC, anon, authenticated, service_role;

COMMIT;

-- make PostgREST see the new signature right away
NOTIFY pgrst, 'reload schema';
