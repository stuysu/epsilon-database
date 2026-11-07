-- Club search that ignores punctuation and matches initials.
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
