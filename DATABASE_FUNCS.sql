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
    )
  )
$$;

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
