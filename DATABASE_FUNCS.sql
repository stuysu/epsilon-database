-- returns ids of rooms that are unavailable
-- frontend will filter out all rooms using that information
create or replace function get_booked_rooms(meeting_start TIMESTAMP, meeting_end TIMESTAMP)
returns setof int
language sql
security definer
set search_path = public
stable
AS $$
  SELECT room_id
  FROM meetings
  WHERE (
    (
      start_time >= meeting_start and
      start_time < meeting_end
    ) or
    (
      end_time > meeting_start and
      end_time <= meeting_end
    )
  )
$$;

CREATE OR REPLACE FUNCTION get_random_organizations(seed_value INT, start_range INT, end_range INT)
RETURNS SETOF organizations
security invoker
set search_path = public
stable
AS $$
BEGIN
    RETURN QUERY 
    SELECT * 
    FROM (
        SELECT *, ROW_NUMBER() OVER (ORDER BY RANDOM(seed_value)) AS row_num
        FROM organizations
    ) AS subquery
    WHERE row_num BETWEEN start_range AND end_range;
END;
$$ LANGUAGE plpgsql;
