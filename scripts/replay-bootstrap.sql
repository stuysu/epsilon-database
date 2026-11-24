-- Stand-ins for what GoTrue and storage-api create on a real Supabase stack.
-- Used by scripts/replay-migrations.sh; anything that already exists is kept.

DO $bootstrap$
BEGIN
  IF to_regprocedure('auth.jwt()') IS NULL THEN
    CREATE FUNCTION auth.jwt()
    RETURNS jsonb
    LANGUAGE sql
    STABLE
    AS $$
      SELECT coalesce(
        nullif(current_setting('request.jwt.claim', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')
      )::jsonb
    $$;
  END IF;

  IF to_regclass('storage.buckets') IS NULL THEN
    CREATE TABLE storage.buckets (
      id text PRIMARY KEY,
      name text NOT NULL UNIQUE,
      owner uuid,
      public boolean DEFAULT false,
      file_size_limit bigint,
      allowed_mime_types text[],
      created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now()
    );
  END IF;

  IF to_regclass('storage.objects') IS NULL THEN
    CREATE TABLE storage.objects (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      bucket_id text REFERENCES storage.buckets (id),
      name text,
      owner uuid,
      metadata jsonb,
      created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now()
    );
    ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
  END IF;

  IF to_regprocedure('storage.foldername(text)') IS NULL THEN
    CREATE FUNCTION storage.foldername(name text)
    RETURNS text[]
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
    DECLARE
      _parts text[];
    BEGIN
      SELECT string_to_array(name, '/') INTO _parts;
      RETURN _parts[1 : array_length(_parts, 1) - 1];
    END
    $$;
  END IF;

  IF to_regprocedure('storage.extension(text)') IS NULL THEN
    CREATE FUNCTION storage.extension(name text)
    RETURNS text
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
    DECLARE
      _parts text[];
      _filename text;
    BEGIN
      SELECT string_to_array(name, '/') INTO _parts;
      SELECT _parts[array_length(_parts, 1)] INTO _filename;
      RETURN reverse(split_part(reverse(_filename), '.', 1));
    END
    $$;
  END IF;
END
$bootstrap$;
