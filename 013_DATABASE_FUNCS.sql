-- returns ids of rooms that are unavailable
-- frontend will filter out all rooms using that information
create or replace function get_booked_rooms(meeting_start TIMESTAMP, meeting_end TIMESTAMP)
returns TABLE (room_id INT, meeting_id INT)
language sql
security definer
set search_path = public
stable
AS $$
  SELECT r.id, m.id
  FROM rooms AS r
  INNER JOIN meetings as m ON (m.room_id = r.id)
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

-- see 026_DISPLAY_LOCKED_ORGS.sql for latest version
CREATE OR REPLACE FUNCTION get_random_organizations(seed FLOAT, query_offset INT, query_limit INT)
RETURNS SETOF organizations
security invoker
set search_path = public
stable
AS $$
BEGIN
    PERFORM setseed(seed);

    RETURN QUERY
    SELECT * 
    FROM organizations
    WHERE organizations.state = 'UNLOCKED' OR organizations.state = 'ADMIN'
    ORDER BY random()
    LIMIT query_limit
    OFFSET query_offset;
END;
$$ LANGUAGE plpgsql;

create or replace function update_profile_picture(profile_url TEXT)
returns boolean
language plpgsql
security definer
set search_path = 'public'
AS $$
BEGIN
  UPDATE users
    SET picture = profile_url
  WHERE users.email = auth.jwt() ->> 'email';

  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION get_unique_meeting_days(month INTEGER, year INTEGER) RETURNS INTEGER[] AS $$
DECLARE
    unique_meeting_days INTEGER[];
BEGIN
    SELECT ARRAY_AGG(DISTINCT EXTRACT(DAY FROM start_time)::INTEGER)
    INTO unique_meeting_days
    FROM public.meetings
    WHERE EXTRACT(MONTH FROM start_time) = month
      AND EXTRACT(YEAR FROM start_time) = year;
    
    RETURN unique_meeting_days;
END;
$$ LANGUAGE plpgsql;
