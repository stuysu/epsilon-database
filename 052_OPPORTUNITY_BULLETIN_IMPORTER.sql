-- lets the scheduled job publish bulletins, and nothing else
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bulletin_importer') THEN
        CREATE ROLE bulletin_importer NOLOGIN NOINHERIT;
    END IF;
END;
$$;
GRANT bulletin_importer TO authenticator;
GRANT USAGE ON SCHEMA public TO bulletin_importer;

GRANT SELECT ON opportunity_categories, opportunity_eligibilities TO bulletin_importer;
GRANT SELECT, INSERT, UPDATE ON opportunity_bulletins TO bulletin_importer;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON opportunities, opportunity_category_links, opportunity_eligibility_links
    TO bulletin_importer;
GRANT USAGE ON SEQUENCE opportunity_bulletins_id_seq, opportunities_id_seq TO bulletin_importer;

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
        EXECUTE format('DROP POLICY IF EXISTS "Scheduled bulletin import" ON public.%I', t);
        EXECUTE format(
            'CREATE POLICY "Scheduled bulletin import" ON public.%I
             FOR ALL TO bulletin_importer USING (true) WITH CHECK (true)',
            t
        );
    END LOOP;
END;
$$;

-- writes still have to go through the import function
CREATE OR REPLACE FUNCTION public.opportunity_writes_via_functions()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF current_user IN ('anon', 'authenticated', 'bulletin_importer')
        AND coalesce(current_setting('opportunities.writing', true), '') <> 'on' THEN
        RAISE EXCEPTION 'Opportunities can only be changed from the Opportunities pages.';
    END IF;
    RETURN coalesce(NEW, OLD);
END;
$$;

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

    -- the scheduled import has no user, so imported_by stays empty
    IF current_user <> 'bulletin_importer' THEN
        SELECT u.id INTO importer_id
        FROM users AS u
        INNER JOIN permissions AS p ON (p.user_id = u.id)
        WHERE u.email = ((select auth.jwt()) ->> 'email') AND p.permission = 'ADMIN';
    END IF;
    IF importer_id IS NULL AND current_user <> 'bulletin_importer' THEN
        RAISE EXCEPTION 'Only site admins can publish a bulletin.';
    END IF;
    PERFORM set_config('opportunities.writing', 'on', true);

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
GRANT EXECUTE ON FUNCTION public.import_opportunity_bulletin(JSONB, JSONB, INT[]) TO authenticated, bulletin_importer;
