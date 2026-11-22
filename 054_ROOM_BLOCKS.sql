-- Site admins can block rooms for whole days. Blocking cancels the meetings
-- in those rooms that day, and clubs can't book them afterwards (Force
-- Reserve still can).
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS public.room_blocks (
  room_id INT NOT NULL REFERENCES rooms (id) ON DELETE CASCADE,
  blocked_on DATE NOT NULL,
  reason VARCHAR(500),
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (room_id, blocked_on)
);

CREATE INDEX IF NOT EXISTS room_blocks_blocked_on_idx ON public.room_blocks (blocked_on);

ALTER TABLE public.room_blocks ENABLE ROW LEVEL SECURITY;

-- club leaders need to see blocks to know which rooms they can pick
DROP POLICY IF EXISTS "Enable read access to all authenticated users" ON public.room_blocks;
CREATE POLICY "Enable read access to all authenticated users"
ON public.room_blocks
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM users AS u
    WHERE (u.email = (auth.jwt() ->> 'email'))
  )
);

DROP POLICY IF EXISTS "Enable all access to site admins" ON public.room_blocks;
CREATE POLICY "Enable all access to site admins"
ON public.room_blocks
FOR ALL
TO authenticated
USING (public.caller_is_site_admin())
WITH CHECK (public.caller_is_site_admin());

-- Blocks the rooms for the day (a New York date) and cancels their meetings
-- that haven't started yet (ones in progress keep their attendance). Rooms an admin club meets in that day are left
-- alone and returned as held. The cancelled meetings are returned so the
-- caller can email their clubs.
CREATE OR REPLACE FUNCTION public.block_rooms(day DATE, room_ids INT[], reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  day_start TIMESTAMPTZ := day::timestamp AT TIME ZONE 'America/New_York';
  day_end TIMESTAMPTZ := (day + 1)::timestamp AT TIME ZONE 'America/New_York';
  note TEXT := nullif(left(btrim(coalesce(reason, '')), 500), '');
  held INT[];
  to_block INT[];
  cancelled JSONB;
BEGIN
  IF NOT public.caller_is_site_admin() THEN
    RAISE EXCEPTION 'Only site admins can block rooms.';
  END IF;

  IF day IS NULL OR day < (now() AT TIME ZONE 'America/New_York')::date THEN
    RAISE EXCEPTION 'Pick today or a later day.';
  END IF;

  IF coalesce(cardinality(room_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Pick at least one room.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(room_ids) AS r(id)
    WHERE NOT EXISTS (SELECT 1 FROM rooms WHERE rooms.id = r.id)
  ) THEN
    RAISE EXCEPTION 'Room not found.';
  END IF;

  -- same lock as bookings, so a meeting can't be booked between the
  -- block and the cancellations
  PERFORM pg_advisory_xact_lock(hashtext('room-booking'), id)
  FROM (SELECT DISTINCT unnest(room_ids) AS id ORDER BY 1) AS r;

  SELECT coalesce(array_agg(DISTINCT m.room_id), '{}') INTO held
  FROM meetings m
  JOIN organizations o ON o.id = m.organization_id
  WHERE m.room_id = ANY (room_ids)
    AND o.state = 'ADMIN'
    AND m.start_time < day_end
    AND m.end_time > day_start
    AND m.start_time > now();

  SELECT coalesce(array_agg(DISTINCT id), '{}') INTO to_block
  FROM unnest(room_ids) AS id
  WHERE NOT id = ANY (held);

  INSERT INTO room_blocks (room_id, blocked_on, reason)
  SELECT id, day, note FROM unnest(to_block) AS id
  ON CONFLICT (room_id, blocked_on) DO UPDATE SET reason = EXCLUDED.reason;

  WITH removed AS (
    DELETE FROM meetings m
    WHERE m.room_id = ANY (to_block)
      AND m.start_time < day_end
      AND m.end_time > day_start
      AND m.start_time > now()
    RETURNING m.id, m.title, m.start_time, m.room_id, m.organization_id
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', removed.id,
    'title', removed.title,
    'start_time', removed.start_time,
    'room_name', r.name,
    'organization_id', removed.organization_id
  ) ORDER BY removed.start_time), '[]'::jsonb) INTO cancelled
  FROM removed
  JOIN rooms r ON r.id = removed.room_id;

  RETURN jsonb_build_object(
    'blocked', to_jsonb(to_block),
    'held', to_jsonb(held),
    'cancelled', cancelled
  );
END;
$$;

REVOKE ALL ON FUNCTION public.block_rooms(DATE, INT[], TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.block_rooms(DATE, INT[], TEXT) TO authenticated;

-- Backstop for every way a club gets a room (create/edit meeting, direct
-- inserts): a blocked room can't be booked on a blocked day. Site admins
-- (Force Reserve) can still book it.
CREATE OR REPLACE FUNCTION public.check_room_block()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.room_id IS NULL OR public.caller_is_site_admin() THEN
    RETURN NEW;
  END IF;

  -- a meeting already in the room keeps it while it stays on the same days
  -- (Force Reserve bookings, or meetings that started before the block)
  IF TG_OP = 'UPDATE'
    AND NEW.room_id IS NOT DISTINCT FROM OLD.room_id
    AND (NEW.start_time AT TIME ZONE 'America/New_York')::date
        >= (OLD.start_time AT TIME ZONE 'America/New_York')::date
    AND ((NEW.end_time - interval '1 microsecond') AT TIME ZONE 'America/New_York')::date
        <= ((OLD.end_time - interval '1 microsecond') AT TIME ZONE 'America/New_York')::date THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('room-booking'), NEW.room_id);

  IF EXISTS (
    SELECT 1 FROM room_blocks b
    WHERE b.room_id = NEW.room_id
      AND b.blocked_on BETWEEN (NEW.start_time AT TIME ZONE 'America/New_York')::date
                           AND ((NEW.end_time - interval '1 microsecond') AT TIME ZONE 'America/New_York')::date
  ) THEN
    RAISE EXCEPTION 'This room is blocked on that day.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS check_room_block ON public.meetings;
CREATE TRIGGER check_room_block
BEFORE INSERT OR UPDATE OF room_id, start_time, end_time ON public.meetings
FOR EACH ROW EXECUTE FUNCTION public.check_room_block();

NOTIFY pgrst, 'reload schema';
