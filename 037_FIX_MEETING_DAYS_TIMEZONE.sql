-- The calendar highlights the days that have meetings, but the day and month
-- were taken from start_time in the database's timezone (UTC). A meeting after
-- 8 PM Eastern landed on the next day, so the wrong day was highlighted. Read
-- them in America/New_York instead, since that is where the school is.
CREATE OR REPLACE FUNCTION get_unique_meeting_days(month INTEGER, year INTEGER) RETURNS INTEGER[] AS $$
DECLARE
    unique_meeting_days INTEGER[];
BEGIN
    SELECT ARRAY_AGG(DISTINCT EXTRACT(DAY FROM start_time AT TIME ZONE 'America/New_York')::INTEGER)
    INTO unique_meeting_days
    FROM public.meetings
    WHERE EXTRACT(MONTH FROM start_time AT TIME ZONE 'America/New_York') = month
      AND EXTRACT(YEAR FROM start_time AT TIME ZONE 'America/New_York') = year;

    RETURN unique_meeting_days;
END;
$$ LANGUAGE plpgsql;
