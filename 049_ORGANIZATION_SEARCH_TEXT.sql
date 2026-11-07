-- Club catalog: search that ignores punctuation and matches initials, and a
-- random order that stays the same between pages.
--
-- The catalog used to strip symbols from what you typed and then look for that
-- text inside the club's name, so "U.N." became "UN" and missed "Model U.N.",
-- and "MSA" never found "Muslim Students Association".
--
-- organization_search_text(text) turns text into lowercase words with the
-- punctuation removed (". ' ’" are dropped, every other symbol becomes a space).
-- public.search_text(organizations) is a PostgREST computed column the catalog
-- filters on. It holds, separated by " | ":
--   the cleaned name                "model un club"
--   the cleaned name with no spaces "modelunclub"
--   the name's initials             "muc"
--   the cleaned keywords
-- The frontend cleans the search box the same way and does an ilike on it.
-- Safe to re-run.

BEGIN;

CREATE OR REPLACE FUNCTION public.organization_search_text(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = ''
AS $$
  SELECT btrim(regexp_replace(
    regexp_replace(lower(coalesce(input, '')), '[.''’]', '', 'g'),
    '[^[:alnum:]]+', ' ', 'g'
  ))
$$;

CREATE OR REPLACE FUNCTION public.search_text(org public.organizations)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT concat_ws(' | ',
    cleaned,
    replace(cleaned, ' ', ''),
    regexp_replace(cleaned, '(\S)\S*\s*', '\1', 'g'),
    public.organization_search_text(org.keywords)
  )
  FROM (SELECT public.organization_search_text(org.name) AS cleaned) AS n
$$;

GRANT EXECUTE ON FUNCTION public.organization_search_text(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.search_text(public.organizations) TO anon, authenticated;

COMMIT;

-- reload PostgREST's schema cache so the new computed column is usable
NOTIFY pgrst, 'reload schema';

-- Stable random order for the catalog.
-- The catalog loads clubs in pages, calling get_random_organizations once per
-- page with the same seed. It used setseed() + ORDER BY random(), which only
-- gives the same order on every call if Postgres reads the rows in the same
-- physical order each time. After a club is edited its row can move, so a club
-- could show up twice or be skipped while scrolling. Ordering by a hash of the
-- seed and the club id gives the same shuffle on every call for a given seed.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_random_organizations(seed double precision, query_offset integer, query_limit integer)
RETURNS SETOF public.organizations
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT *
  FROM organizations
  WHERE organizations.state IN ('UNLOCKED', 'ADMIN', 'LOCKED')
  ORDER BY md5(seed::text || ':' || organizations.id::text), organizations.id
  LIMIT query_limit
  OFFSET query_offset
$$;

COMMIT;
