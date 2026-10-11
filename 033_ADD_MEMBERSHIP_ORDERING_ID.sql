-- Lets org admins manually reorder the member list (stuysu/epsilon#218).
-- Lower numbers are displayed first. NULL (the default) means the member has
-- not been ordered and goes after ordered members, in join order.
ALTER TABLE memberships ADD COLUMN IF NOT EXISTS ordering_id INT;
