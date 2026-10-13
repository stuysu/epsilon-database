-- Meetings of the Epsilon Maintenance club (url "epsilon") are internal and are
-- not shown on the calendar, so they should not highlight a day there either.
CREATE OR REPLACE FUNCTION get_unique_meeting_days(month INTEGER, year INTEGER) RETURNS INTEGER[] AS $$
DECLARE
    unique_meeting_days INTEGER[];
BEGIN
    SELECT ARRAY_AGG(DISTINCT EXTRACT(DAY FROM m.start_time AT TIME ZONE 'America/New_York')::INTEGER)
    INTO unique_meeting_days
    FROM public.meetings m
    JOIN public.organizations o ON o.id = m.organization_id
    WHERE o.url <> 'epsilon'
      AND EXTRACT(MONTH FROM m.start_time AT TIME ZONE 'America/New_York') = month
      AND EXTRACT(YEAR FROM m.start_time AT TIME ZONE 'America/New_York') = year;

    RETURN unique_meeting_days;
END;
$$ LANGUAGE plpgsql;
