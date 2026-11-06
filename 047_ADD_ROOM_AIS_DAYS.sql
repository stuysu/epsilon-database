-- The AIS days set for a room on the admin Rooms page.
-- update-room and force-reserve already read and write this column, but no
-- earlier migration created it, so a database built from these files was
-- missing it. IF NOT EXISTS keeps this safe where it was added by hand.
ALTER TABLE public.rooms ADD COLUMN IF NOT EXISTS ais_days TEXT[];
