-- Opportunities module: the catalog is driven by the weekly Student Opportunity
-- Bulletin, which site admins upload and review before publishing.

BEGIN;

CREATE TABLE opportunity_categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    -- deleting a main category must not quietly take its sub-categories with it
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

-- Only plain web addresses may be stored, so no page can render a javascript: link.
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
    first_bulletin_id INT NULL REFERENCES opportunity_bulletins(id) ON DELETE SET NULL,
    last_bulletin_id INT NULL REFERENCES opportunity_bulletins(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

create extension if not exists moddatetime schema extensions;

-- trigger to update "updated_at" field before every update to row
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

-- Catalog tables: Epsilon users can read, site admins can write. Any Google
-- account can sign in, so reading also requires a row in users.
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

-- Which file was uploaded, and by whom, is for admins only. Students can still
-- read everything the site shows about a bulletin.
REVOKE SELECT ON opportunity_bulletins FROM anon, authenticated;
GRANT SELECT (id, issue, published_on, entry_count, imported_at) ON opportunity_bulletins TO authenticated;

-- Saved opportunities: each user only sees and changes their own.
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

-- Publishes a reviewed bulletin in one transaction. Runs as the caller, so the
-- admin-only policies above decide who may write. An entry that matched an
-- existing opportunity during review carries its id, so a corrected title still
-- updates that opportunity; other entries match on title_key. Either way the id,
-- and so students' saved lists, carry over from week to week.
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
    -- every opportunity this bulletin lists, so re-importing the same issue
    -- still archives and clears labels on whatever it dropped
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

    -- one import at a time, so two admins publishing at once can't let an
    -- older issue slip past the check below and overwrite a newer one
    PERFORM pg_advisory_xact_lock(hashtext('public.import_opportunity_bulletin'));

    -- an older issue would roll descriptions back and archive newer listings
    IF EXISTS (SELECT 1 FROM opportunity_bulletins WHERE published_on > published) THEN
        RAISE EXCEPTION 'A newer bulletin has already been published, so this older one can''t be imported.';
    END IF;
    -- the Long issue lists everything its Short version does, so the Short one
    -- would only clear the Long one's labels
    IF issue_number LIKE '%S' AND EXISTS (
        SELECT 1 FROM opportunity_bulletins
        WHERE published_on = published
            AND upper(issue) = left(issue_number, -1) || 'L'
    ) THEN
        RAISE EXCEPTION 'Bulletin #%L from the same day is already published, and it lists everything #% does.',
            left(issue_number, -1), issue_number;
    END IF;

    -- file_name and imported_by are hidden from the API, so they are written
    -- from the arguments rather than read back through EXCLUDED
    INSERT INTO opportunity_bulletins (issue, published_on, file_name, entry_count, imported_by)
    VALUES (issue_number, published, bulletin ->> 'file_name', jsonb_array_length(entries), importer_id)
    ON CONFLICT (issue, published_on) DO UPDATE SET
        file_name = bulletin ->> 'file_name',
        entry_count = jsonb_array_length(entries),
        imported_by = importer_id,
        imported_at = CURRENT_TIMESTAMP
    RETURNING id INTO new_bulletin_id;

    -- Free the titles of every listing updated by id first, so renames can swap
    -- or chain, and no entry matched by title can land on a listing that another
    -- entry is renaming. The placeholder has a hyphen, which no real key does.
    UPDATE opportunities SET title_key = 'renaming-' || id
    WHERE id IN (
        SELECT (e ->> 'id')::INT FROM jsonb_array_elements(entries) AS e
        WHERE e ->> 'id' IS NOT NULL
    );

    -- entries with an id go first, for the same reason
    FOR entry IN
        SELECT e FROM jsonb_array_elements(entries) AS e
        ORDER BY (e ->> 'id' IS NULL)
    LOOP
        existing_id := (entry ->> 'id')::INT;
        new_opportunity_id := NULL;

        BEGIN
            IF existing_id IS NOT NULL THEN
                UPDATE opportunities SET
                    title = entry ->> 'title',
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
                    archived = false,
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
                    entry ->> 'title',
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
                    archived = false,
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
        INSERT INTO opportunity_eligibility_links (opportunity_id, eligibility_id)
        SELECT new_opportunity_id, value::INT
        FROM jsonb_array_elements_text(entry -> 'eligibility_ids');
    END LOOP;

    -- anything this bulletin lists stays active, even if it was also marked to archive
    UPDATE opportunities SET archived = true
    WHERE id = ANY(archive_ids)
        AND NOT (id = ANY(listed_ids))
        AND NOT archived;

    -- labels such as "New" or "Deadline Today" only describe the latest bulletin
    UPDATE opportunities SET bulletin_label = NULL
    WHERE bulletin_label IS NOT NULL
        AND NOT (id = ANY(listed_ids));

    RETURN new_bulletin_id;
END;
$$;

REVOKE ALL ON FUNCTION public.import_opportunity_bulletin(JSONB, JSONB, INT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_opportunity_bulletin(JSONB, JSONB, INT[]) TO authenticated;

-- Categories as they are organized in the bulletin.
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
