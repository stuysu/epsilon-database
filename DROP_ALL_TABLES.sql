-- Wipes everything the numbered migrations create, so they can be replayed on
-- a LOCAL database. Never run this on production. Run it as the owner of the
-- schema (supabase_admin on Supabase):
--
--   psql -U supabase_admin -v drop_everything=yes -f DROP_ALL_TABLES.sql
--
-- Drops every table, view, function, procedure, enum/domain type and sequence
-- in public, the storage.objects upload policy, and the bulletin_importer role.
-- Extensions, the auth/storage schemas and buckets are left alone.

\if :{?drop_everything}
\else
\set drop_everything false
\endif
\if :drop_everything
\else
\echo 'Refusing. Run with: psql -U supabase_admin -v drop_everything=yes -f DROP_ALL_TABLES.sql'
\quit
\endif

\set ON_ERROR_STOP on

BEGIN;
SET LOCAL client_min_messages = warning;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.oid, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
  LOOP
    -- an earlier CASCADE may have dropped it already
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = r.oid);
    EXECUTE format(
      'DROP %s IF EXISTS %s CASCADE',
      CASE r.relkind
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'f' THEN 'FOREIGN TABLE'
        ELSE 'TABLE'
      END,
      r.oid::regclass
    );
  END LOOP;

  FOR r IN
    SELECT p.oid, p.prokind
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.oid);
    EXECUTE format(
      'DROP %s IF EXISTS %s CASCADE',
      CASE r.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
      r.oid::regprocedure
    );
  END LOOP;

  FOR r IN
    SELECT t.oid, t.typtype
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND t.typtype IN ('e', 'd', 'c')
      AND (t.typrelid = 0 OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')
  LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_type WHERE oid = r.oid);
    EXECUTE format(
      'DROP %s IF EXISTS %s CASCADE',
      CASE r.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END,
      r.oid::regtype
    );
  END LOOP;

  FOR r IN
    SELECT c.oid
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'S'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
  LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = r.oid);
    EXECUTE format('DROP SEQUENCE IF EXISTS %s CASCADE', r.oid::regclass);
  END LOOP;

  IF to_regclass('storage.objects') IS NOT NULL THEN
    DROP POLICY IF EXISTS "Allow verified users to upload files" ON storage.objects;
    -- 055's; its other storage policies go with is_apply_admin()
    DROP POLICY IF EXISTS "Enable public read access to application files" ON storage.objects;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bulletin_importer') THEN
    DROP OWNED BY bulletin_importer;
    DROP ROLE bulletin_importer;
  END IF;
END $$;

COMMIT;
