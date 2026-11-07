-- Catalog search: ignores punctuation and matches initials.

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

NOTIFY pgrst, 'reload schema';

-- Same shuffle on every page for a given seed.
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
