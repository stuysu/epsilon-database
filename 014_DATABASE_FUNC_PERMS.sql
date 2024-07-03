ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Choose which roles can execute functions
GRANT EXECUTE ON FUNCTION add_creator TO postgres; -- let database add creator to intiial organization
GRANT EXECUTE ON FUNCTION get_user_admin_organizations TO postgres; -- get organizations user is admin of
GRANT EXECUTE ON FUNCTION get_user_creator_organizations TO postgres; -- get organizations user is creator of 
GRANT EXECUTE ON FUNCTION is_admin TO postgres; -- check if user is admin of site
GRANT EXECUTE ON FUNCTION get_booked_rooms TO authenticated; -- allow club leaders (those signed in) to get booked rooms within a timestamp
GRANT EXECUTE ON FUNCTION get_random_organizations TO anon;
GRANT EXECUTE ON FUNCTION update_profile_picture TO authenticated;
GRANT EXECUTE ON FUNCTION get_unique_meeting_days TO anon;
