-- Opportunities, driven by the weekly Student Opportunity Bulletin.

BEGIN;

CREATE TABLE opportunity_categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    -- a main category can't take its sub-categories with it
    parent_id INT NULL REFERENCES opportunity_categories(id) ON DELETE RESTRICT,
    position INT DEFAULT 0 NOT NULL
);

CREATE TABLE opportunity_eligibilities (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    grade INT NULL CHECK (grade BETWEEN 9 AND 12), -- NULL for group-based tags
    position INT DEFAULT 0 NOT NULL
);

CREATE TABLE opportunity_bulletins (
    id SERIAL PRIMARY KEY,
    issue TEXT NOT NULL, -- e.g. "8L"; numbering restarts every school year
    published_on DATE NOT NULL,
    file_name TEXT NULL,
    entry_count INT DEFAULT 0 NOT NULL,
    imported_by INT NULL REFERENCES users(id) ON DELETE SET NULL,
    imported_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (issue, published_on)
);

-- plain web addresses only, so no javascript: links
CREATE OR REPLACE FUNCTION public.opportunity_links_are_safe(links TEXT[])
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT coalesce(bool_and(link IS NOT NULL AND link ~* '^https?://'), true)
    FROM unnest(links) AS link;
$$;

CREATE TABLE opportunities (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL CHECK (btrim(title) <> ''),
    title_key TEXT UNIQUE NOT NULL CHECK (title_key <> ''), -- matches an opportunity across weekly bulletins
    description TEXT DEFAULT '' NOT NULL,
    date_text TEXT NULL,
    location TEXT NULL,
    cost_text TEXT NULL, -- as written in the bulletin
    cost_min INT NULL CHECK (cost_min >= 0), -- NULL when no price can be read
    cost_max INT NULL CHECK (cost_max >= cost_min),
    deadline DATE NULL, -- latest date in deadline_text; ends 23:59:59 Eastern
    deadline_text TEXT NULL, -- as written, e.g. "Rolling Basis" or "TBD"
    eligibility_text TEXT NULL, -- as written; ages and GPAs only live here
    links TEXT[] DEFAULT '{}' NOT NULL CHECK (opportunity_links_are_safe(links)),
    bulletin_label TEXT NULL, -- e.g. "New"; only kept while the latest bulletin lists it
    archived BOOLEAN DEFAULT false NOT NULL, -- past deadlines count as archived automatically
    edited_fields TEXT[] DEFAULT '{}' NOT NULL, -- changed by an admin; the review keeps these over the bulletin's
    edited_at TIMESTAMPTZ, -- last admin edit, so an import can't undo one made mid-review
    first_bulletin_id INT NULL REFERENCES opportunity_bulletins(id) ON DELETE SET NULL,
    last_bulletin_id INT NULL REFERENCES opportunity_bulletins(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

create extension if not exists moddatetime schema extensions;

create trigger handle_updated_at before update on opportunities
  for each row execute procedure moddatetime (updated_at);

CREATE TABLE opportunity_category_links (
    opportunity_id INT NOT NULL REFERENCES opportunities(id) ON DELETE CASCADE,
    category_id INT NOT NULL REFERENCES opportunity_categories(id) ON DELETE CASCADE,
    PRIMARY KEY (opportunity_id, category_id)
);

CREATE TABLE opportunity_eligibility_links (
    opportunity_id INT NOT NULL REFERENCES opportunities(id) ON DELETE CASCADE,
    eligibility_id INT NOT NULL REFERENCES opportunity_eligibilities(id) ON DELETE CASCADE,
    preferred BOOLEAN NOT NULL DEFAULT false, -- "especially for", not a limit
    PRIMARY KEY (opportunity_id, eligibility_id)
);

CREATE TABLE saved_opportunities (
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    opportunity_id INT NOT NULL REFERENCES opportunities(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, opportunity_id)
);

CREATE INDEX saved_opportunities_opportunity_id_idx ON saved_opportunities(opportunity_id);
CREATE INDEX opportunity_category_links_category_id_idx ON opportunity_category_links(category_id);
CREATE INDEX opportunity_eligibility_links_eligibility_id_idx ON opportunity_eligibility_links(eligibility_id);
CREATE INDEX opportunity_categories_parent_id_idx ON opportunity_categories(parent_id);
CREATE INDEX opportunity_bulletins_imported_by_idx ON opportunity_bulletins(imported_by);
CREATE INDEX opportunities_first_bulletin_id_idx ON opportunities(first_bulletin_id);
CREATE INDEX opportunities_last_bulletin_id_idx ON opportunities(last_bulletin_id);

-- users can read, site admins can write; reading needs a row in users
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'opportunities',
        'opportunity_bulletins',
        'opportunity_categories',
        'opportunity_eligibilities',
        'opportunity_category_links',
        'opportunity_eligibility_links'
    ]
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

        EXECUTE format(
            $policy$
            CREATE POLICY "Enable read access to all authenticated users" ON public.%I
            FOR SELECT
            TO authenticated
            USING (
                EXISTS (
                    SELECT 1
                    FROM users AS u
                    WHERE u.email = ((select auth.jwt()) ->> 'email')
                )
            )
            $policy$,
            t
        );

        EXECUTE format(
            $policy$
            CREATE POLICY "Enable all access to site admins" ON public.%I
            FOR ALL
            TO authenticated
            USING (
                EXISTS (
                    SELECT 1
                    FROM permissions AS p
                    INNER JOIN users AS u ON (p.user_id = u.id)
                    WHERE u.email = ((select auth.jwt()) ->> 'email') AND p.permission = 'ADMIN'
                )
            )
            WITH CHECK (
                EXISTS (
                    SELECT 1
                    FROM permissions AS p
                    INNER JOIN users AS u ON (p.user_id = u.id)
                    WHERE u.email = ((select auth.jwt()) ->> 'email') AND p.permission = 'ADMIN'
                )
            )
            $policy$,
            t
        );
    END LOOP;
END;
$$;

-- file_name and imported_by are admin-only
REVOKE SELECT ON opportunity_bulletins FROM anon, authenticated;
GRANT SELECT (id, issue, published_on, entry_count, imported_at) ON opportunity_bulletins TO authenticated;

ALTER TABLE saved_opportunities ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage their own saved opportunities"
ON public.saved_opportunities
FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1
        FROM users AS u
        WHERE u.id = saved_opportunities.user_id AND u.email = ((select auth.jwt()) ->> 'email')
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM users AS u
        WHERE u.id = saved_opportunities.user_id AND u.email = ((select auth.jwt()) ->> 'email')
    )
);

-- Publishes a reviewed bulletin in one transaction, as the caller, so the admin-only policies apply.
-- Entries with an id update that row, others match on title_key, so saved lists carry over.
CREATE OR REPLACE FUNCTION public.import_opportunity_bulletin(
    bulletin JSONB,
    entries JSONB,
    archive_ids INT[] DEFAULT '{}'
)
RETURNS INT
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    issue_number TEXT := upper(btrim(bulletin ->> 'issue'));
    published DATE := (bulletin ->> 'published_on')::DATE;
    importer_id INT;
    new_bulletin_id INT;
    entry JSONB;
    existing_id INT;
    new_opportunity_id INT;
    -- every listing this bulletin has, even on a re-import
    listed_ids INT[] := '{}';
    bad_link_title TEXT;
BEGIN
    IF coalesce(issue_number, '') = '' OR published IS NULL THEN
        RAISE EXCEPTION 'The bulletin needs an issue number and a date.';
    END IF;
    IF published > current_date + 14 THEN
        RAISE EXCEPTION 'This bulletin is dated %, more than two weeks from now. Check the date on its cover.', published;
    END IF;
    IF entries IS NULL OR jsonb_typeof(entries) <> 'array' OR jsonb_array_length(entries) = 0 THEN
        RAISE EXCEPTION 'This bulletin has no opportunities to publish.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(entries) AS e
        WHERE coalesce(btrim(e ->> 'title'), '') = '' OR coalesce(btrim(e ->> 'title_key'), '') = ''
    ) THEN
        RAISE EXCEPTION 'Every opportunity needs a title.';
    END IF;
    IF (SELECT count(DISTINCT e ->> 'title_key') FROM jsonb_array_elements(entries) AS e)
        <> jsonb_array_length(entries) THEN
        RAISE EXCEPTION 'Two opportunities in this bulletin have the same title.';
    END IF;
    -- compared as numbers, so 1 and "01" count as the same listing
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(entries) AS e
        WHERE e ->> 'id' IS NOT NULL
        GROUP BY (e ->> 'id')::INT
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Two opportunities in this bulletin update the same existing listing.';
    END IF;
    SELECT e ->> 'title' INTO bad_link_title
    FROM jsonb_array_elements(entries) AS e,
        jsonb_array_elements_text(coalesce(e -> 'links', '[]'::JSONB)) AS link
    WHERE link IS NULL OR link !~* '^https?://'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION '"%" has a link that doesn''t start with http:// or https://.', bad_link_title;
    END IF;

    SELECT u.id INTO importer_id
    FROM users AS u
    INNER JOIN permissions AS p ON (p.user_id = u.id)
    WHERE u.email = ((select auth.jwt()) ->> 'email') AND p.permission = 'ADMIN';
    IF importer_id IS NULL THEN
        RAISE EXCEPTION 'Only site admins can publish a bulletin.';
    END IF;

    -- one import at a time, so the older-issue check below can't race
    PERFORM pg_advisory_xact_lock(hashtext('public.import_opportunity_bulletin'));

    IF EXISTS (SELECT 1 FROM opportunity_bulletins WHERE published_on > published) THEN
        RAISE EXCEPTION 'A newer bulletin has already been published, so this older one can''t be imported.';
    END IF;
    -- a Short issue would only clear its Long issue's labels
    IF issue_number LIKE '%S' AND EXISTS (
        SELECT 1 FROM opportunity_bulletins
        WHERE published_on = published
            AND upper(issue) = left(issue_number, -1) || 'L'
    ) THEN
        RAISE EXCEPTION 'Bulletin #%L from the same day is already published, and it lists everything #% does.',
            left(issue_number, -1), issue_number;
    END IF;

    -- these columns are hidden from the API, so not read back through EXCLUDED
    INSERT INTO opportunity_bulletins (issue, published_on, file_name, entry_count, imported_by)
    VALUES (issue_number, published, bulletin ->> 'file_name', jsonb_array_length(entries), importer_id)
    ON CONFLICT (issue, published_on) DO UPDATE SET
        file_name = bulletin ->> 'file_name',
        entry_count = jsonb_array_length(entries),
        imported_by = importer_id,
        imported_at = CURRENT_TIMESTAMP
    RETURNING id INTO new_bulletin_id;

    -- free the titles of listings updated by id first, so renames can swap or chain; no real key has a hyphen
    UPDATE opportunities SET title_key = 'renaming-' || id
    WHERE id IN (
        SELECT (e ->> 'id')::INT FROM jsonb_array_elements(entries) AS e
        WHERE e ->> 'id' IS NOT NULL
    );

    -- entries with an id go first
    FOR entry IN
        SELECT e FROM jsonb_array_elements(entries) AS e
        ORDER BY (e ->> 'id' IS NULL)
    LOOP
        existing_id := (entry ->> 'id')::INT;
        new_opportunity_id := NULL;

        BEGIN
            -- locked first, so an edit can't land between the check and the update
            PERFORM 1 FROM opportunities WHERE id = existing_id FOR UPDATE;
            IF existing_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM opportunities AS o
                WHERE o.id = existing_id
                    AND o.edited_at IS DISTINCT FROM (entry ->> 'edited_at')::TIMESTAMPTZ
            ) THEN
                RAISE EXCEPTION '"%" was edited while this bulletin was being reviewed. Choose the PDF again to include that edit.', entry ->> 'title';
            END IF;
            -- the review would have matched it, so it was added since and may hold edits
            IF existing_id IS NULL AND EXISTS (
                SELECT 1 FROM opportunities WHERE title_key = entry ->> 'title_key'
            ) THEN
                RAISE EXCEPTION '"%" was added while this bulletin was being reviewed. Choose the PDF again to include it.', entry ->> 'title';
            END IF;

            IF existing_id IS NOT NULL THEN
                UPDATE opportunities SET
                    title = btrim(entry ->> 'title'),
                    title_key = entry ->> 'title_key',
                    description = COALESCE(entry ->> 'description', ''),
                    date_text = entry ->> 'date_text',
                    location = entry ->> 'location',
                    cost_text = entry ->> 'cost_text',
                    cost_min = (entry ->> 'cost_min')::INT,
                    cost_max = (entry ->> 'cost_max')::INT,
                    deadline = (entry ->> 'deadline')::DATE,
                    deadline_text = entry ->> 'deadline_text',
                    eligibility_text = entry ->> 'eligibility_text',
                    links = ARRAY(SELECT jsonb_array_elements_text(entry -> 'links')),
                    bulletin_label = entry ->> 'bulletin_label',
                    archived = archived AND 'archived' = ANY(edited_fields),
                    last_bulletin_id = new_bulletin_id
                WHERE id = existing_id
                RETURNING id INTO new_opportunity_id;
            END IF;

            -- a new listing, or one whose id no longer exists
            IF new_opportunity_id IS NULL THEN
                INSERT INTO opportunities (
                    title, title_key, description, date_text, location, cost_text, cost_min,
                    cost_max, deadline, deadline_text, eligibility_text, links, bulletin_label,
                    archived, first_bulletin_id, last_bulletin_id
                )
                VALUES (
                    btrim(entry ->> 'title'),
                    entry ->> 'title_key',
                    COALESCE(entry ->> 'description', ''),
                    entry ->> 'date_text',
                    entry ->> 'location',
                    entry ->> 'cost_text',
                    (entry ->> 'cost_min')::INT,
                    (entry ->> 'cost_max')::INT,
                    (entry ->> 'deadline')::DATE,
                    entry ->> 'deadline_text',
                    entry ->> 'eligibility_text',
                    ARRAY(SELECT jsonb_array_elements_text(entry -> 'links')),
                    entry ->> 'bulletin_label',
                    false,
                    new_bulletin_id,
                    new_bulletin_id
                )
                ON CONFLICT (title_key) DO UPDATE SET
                    title = EXCLUDED.title,
                    description = EXCLUDED.description,
                    date_text = EXCLUDED.date_text,
                    location = EXCLUDED.location,
                    cost_text = EXCLUDED.cost_text,
                    cost_min = EXCLUDED.cost_min,
                    cost_max = EXCLUDED.cost_max,
                    deadline = EXCLUDED.deadline,
                    deadline_text = EXCLUDED.deadline_text,
                    eligibility_text = EXCLUDED.eligibility_text,
                    links = EXCLUDED.links,
                    bulletin_label = EXCLUDED.bulletin_label,
                    archived = opportunities.archived AND 'archived' = ANY(opportunities.edited_fields),
                    last_bulletin_id = EXCLUDED.last_bulletin_id
                RETURNING id INTO new_opportunity_id;
            END IF;
        EXCEPTION WHEN unique_violation THEN
            -- renaming a listing onto the title of a different one
            RAISE EXCEPTION '"%" has the same title as another opportunity. Rename one of them, then publish again.', entry ->> 'title';
        END;

        listed_ids := listed_ids || new_opportunity_id;

        DELETE FROM opportunity_category_links WHERE opportunity_id = new_opportunity_id;
        INSERT INTO opportunity_category_links (opportunity_id, category_id)
        SELECT new_opportunity_id, value::INT
        FROM jsonb_array_elements_text(entry -> 'category_ids');

        DELETE FROM opportunity_eligibility_links WHERE opportunity_id = new_opportunity_id;
        INSERT INTO opportunity_eligibility_links (opportunity_id, eligibility_id, preferred)
        SELECT new_opportunity_id, value::INT, false
        FROM jsonb_array_elements_text(entry -> 'eligibility_ids')
        UNION
        SELECT new_opportunity_id, value::INT, true
        FROM jsonb_array_elements_text(COALESCE(entry -> 'preferred_eligibility_ids', '[]'))
        WHERE NOT coalesce(entry -> 'eligibility_ids', '[]') @> jsonb_build_array(value::INT)
        ON CONFLICT DO NOTHING;
    END LOOP;

    -- listed ones stay active even if also marked to archive
    UPDATE opportunities SET archived = true
    WHERE id = ANY(coalesce(archive_ids, '{}'))
        AND NOT (id = ANY(listed_ids))
        AND NOT archived
        AND NOT 'archived' = ANY(edited_fields);

    -- labels only describe the latest bulletin
    UPDATE opportunities SET bulletin_label = NULL
    WHERE bulletin_label IS NOT NULL
        AND NOT (id = ANY(listed_ids));

    RETURN new_bulletin_id;
END;
$$;

REVOKE ALL ON FUNCTION public.import_opportunity_bulletin(JSONB, JSONB, INT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_opportunity_bulletin(JSONB, JSONB, INT[]) TO authenticated;

-- an admin's edit of one listing; title_key stays so later bulletins still match it
CREATE OR REPLACE FUNCTION public.update_opportunity(
    opportunity_id INT,
    fields JSONB,
    category_ids INT[],
    eligibility_ids INT[] DEFAULT '{}',
    preferred_eligibility_ids INT[] DEFAULT '{}'
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    old opportunities;
    new_links TEXT[] := ARRAY(SELECT jsonb_array_elements_text(coalesce(fields -> 'links', '[]')));
    preferred_ids INT[] := ARRAY(
        SELECT DISTINCT unnest(preferred_eligibility_ids) EXCEPT SELECT unnest(eligibility_ids)
    );
    edited TEXT[] := '{}';
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM permissions AS p
        INNER JOIN users AS u ON (p.user_id = u.id)
        WHERE u.email = ((select auth.jwt()) ->> 'email') AND p.permission = 'ADMIN'
    ) THEN
        RAISE EXCEPTION 'Only site admins can edit opportunities.';
    END IF;
    IF coalesce(btrim(fields ->> 'title'), '') = '' THEN
        RAISE EXCEPTION 'The opportunity needs a title.';
    END IF;
    IF coalesce(cardinality(category_ids), 0) = 0 THEN
        RAISE EXCEPTION 'The opportunity needs a category.';
    END IF;
    IF NOT opportunity_links_are_safe(new_links) THEN
        RAISE EXCEPTION 'Every link must start with http:// or https://.';
    END IF;

    SELECT * INTO old FROM opportunities WHERE id = opportunity_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'This opportunity no longer exists.';
    END IF;
    -- saving an old copy would undo a newer bulletin and lock its values in
    IF old.updated_at IS DISTINCT FROM (fields ->> 'updated_at')::TIMESTAMPTZ THEN
        RAISE EXCEPTION 'This opportunity changed after you opened it. Refresh the page, then make your edit again.';
    END IF;

    IF old.title IS DISTINCT FROM btrim(fields ->> 'title') THEN edited := array_append(edited, 'title'); END IF;
    IF old.description IS DISTINCT FROM coalesce(fields ->> 'description', '') THEN edited := array_append(edited, 'description'); END IF;
    IF old.date_text IS DISTINCT FROM fields ->> 'date_text' THEN edited := array_append(edited, 'date_text'); END IF;
    IF old.location IS DISTINCT FROM fields ->> 'location' THEN edited := array_append(edited, 'location'); END IF;
    IF old.cost_text IS DISTINCT FROM fields ->> 'cost_text'
        OR old.cost_min IS DISTINCT FROM (fields ->> 'cost_min')::INT
        OR old.cost_max IS DISTINCT FROM (fields ->> 'cost_max')::INT THEN edited := array_append(edited, 'cost_text'); END IF;
    IF old.deadline IS DISTINCT FROM (fields ->> 'deadline')::DATE
        OR old.deadline_text IS DISTINCT FROM fields ->> 'deadline_text' THEN edited := array_append(edited, 'deadline'); END IF;
    IF old.eligibility_text IS DISTINCT FROM fields ->> 'eligibility_text' THEN edited := array_append(edited, 'eligibility_text'); END IF;
    IF old.links IS DISTINCT FROM new_links THEN edited := array_append(edited, 'links'); END IF;
    IF old.archived IS DISTINCT FROM coalesce((fields ->> 'archived')::BOOLEAN, old.archived) THEN edited := array_append(edited, 'archived'); END IF;
    IF ARRAY(SELECT category_id FROM opportunity_category_links WHERE opportunity_category_links.opportunity_id = old.id ORDER BY 1)
        IS DISTINCT FROM ARRAY(SELECT DISTINCT unnest(category_ids) ORDER BY 1) THEN
        edited := array_append(edited, 'categories');
    END IF;
    IF ARRAY(SELECT (eligibility_id, preferred)::TEXT FROM opportunity_eligibility_links AS l WHERE l.opportunity_id = old.id ORDER BY 1)
        IS DISTINCT FROM ARRAY(
            SELECT (id, preferred)::TEXT FROM (
                SELECT DISTINCT unnest(eligibility_ids) AS id, false AS preferred
                UNION SELECT unnest(preferred_ids), true
            ) AS t ORDER BY 1
        ) THEN
        edited := array_append(edited, 'eligibilities');
    END IF;

    UPDATE opportunities SET
        title = btrim(fields ->> 'title'),
        description = coalesce(fields ->> 'description', ''),
        date_text = fields ->> 'date_text',
        location = fields ->> 'location',
        cost_text = fields ->> 'cost_text',
        cost_min = (fields ->> 'cost_min')::INT,
        cost_max = (fields ->> 'cost_max')::INT,
        deadline = (fields ->> 'deadline')::DATE,
        deadline_text = fields ->> 'deadline_text',
        eligibility_text = fields ->> 'eligibility_text',
        links = new_links,
        archived = coalesce((fields ->> 'archived')::BOOLEAN, archived),
        edited_fields = ARRAY(SELECT DISTINCT unnest(edited_fields || edited) ORDER BY 1),
        edited_at = CASE WHEN cardinality(edited) > 0 THEN now() ELSE edited_at END
    WHERE id = old.id;

    DELETE FROM opportunity_category_links WHERE opportunity_category_links.opportunity_id = old.id;
    INSERT INTO opportunity_category_links (opportunity_id, category_id)
    SELECT DISTINCT old.id, unnest(category_ids);

    DELETE FROM opportunity_eligibility_links AS l WHERE l.opportunity_id = old.id;
    INSERT INTO opportunity_eligibility_links (opportunity_id, eligibility_id, preferred)
    SELECT DISTINCT old.id, unnest(eligibility_ids), false
    UNION SELECT old.id, unnest(preferred_ids), true;
END;
$$;

REVOKE ALL ON FUNCTION public.update_opportunity(INT, JSONB, INT[], INT[], INT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_opportunity(INT, JSONB, INT[], INT[], INT[]) TO authenticated;

INSERT INTO opportunity_categories (name, position) VALUES
    ('Events of Interest', 1),
    ('Academic Programs', 2),
    ('Business & Jobs', 3),
    ('Community Service', 4),
    ('College Prep', 5),
    ('Leadership, Government, Law, Advocacy, International', 6),
    ('Museums, Art & Photography', 7),
    ('Parks & Nature', 8),
    ('STEM Opportunities', 9),
    ('Theater, Writing, Music, Performing Arts, Video', 10),
    ('Contests & Competitions', 11),
    ('Opportunity Lists & Resources', 12),
    ('Scholarships', 13);

INSERT INTO opportunity_categories (name, parent_id, position)
SELECT child.name, parent.id, child.position
FROM (VALUES
    ('Engineering, Math & Computer Science', 1),
    ('Medical & Life Sciences', 2)
) AS child(name, position)
CROSS JOIN opportunity_categories AS parent
WHERE parent.name = 'STEM Opportunities';

INSERT INTO opportunity_eligibilities (name, grade, position) VALUES
    ('Freshman', 9, 1),
    ('Sophomore', 10, 2),
    ('Junior', 11, 3),
    ('Senior', 12, 4),
    ('Female', NULL, 5),
    ('Nonbinary', NULL, 6),
    ('Disadvantaged', NULL, 7),
    ('Underrepresented', NULL, 8),
    ('Needs Financial Aid', NULL, 9);

COMMIT;
