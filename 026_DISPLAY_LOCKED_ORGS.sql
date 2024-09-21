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
    WHERE organizations.state = 'UNLOCKED' OR organizations.state = 'ADMIN' OR organizations.state = 'LOCKED'
    ORDER BY random()
    LIMIT query_limit
    OFFSET query_offset;
END;
$$ LANGUAGE plpgsql;
