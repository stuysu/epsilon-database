-- Opportunities module: the catalog is driven by the weekly Student Opportunity
-- Bulletin, which site admins upload and review before publishing.

CREATE TABLE opportunity_categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) UNIQUE NOT NULL,
    parent_id INT NULL REFERENCES opportunity_categories(id) ON DELETE CASCADE,
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
    issue TEXT UNIQUE NOT NULL, -- e.g. "8L"
    published_on DATE NOT NULL,
    file_name TEXT NULL,
    entry_count INT DEFAULT 0 NOT NULL,
    imported_by INT NULL REFERENCES users(id) ON DELETE SET NULL,
    imported_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE opportunities (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    title_key TEXT UNIQUE NOT NULL, -- matches an opportunity across weekly bulletins
    description TEXT DEFAULT '' NOT NULL,
    date_text TEXT NULL,
    location TEXT NULL,
    cost_text TEXT NULL, -- as written in the bulletin
    cost_min INT NULL CHECK (cost_min >= 0), -- NULL when no price can be read
    cost_max INT NULL CHECK (cost_max >= cost_min),
    deadline DATE NULL, -- latest date in deadline_text; ends 23:59:59 Eastern
    deadline_text TEXT NULL, -- as written, e.g. "Rolling Basis" or "TBD"
    eligibility_text TEXT NULL, -- as written; ages and GPAs only live here
    links TEXT[] DEFAULT '{}' NOT NULL,
    bulletin_label TEXT NULL, -- e.g. "New" or "Deadline Approaching"
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

-- Catalog tables: any signed-in user can read, site admins can write.
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
            'CREATE POLICY "Enable read access to authenticated users only" ON public.%I FOR SELECT TO authenticated USING (true)',
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
                    WHERE u.email = auth.jwt() ->> 'email' AND p.permission = 'ADMIN'
                )
            )
            WITH CHECK (
                EXISTS (
                    SELECT 1
                    FROM permissions AS p
                    INNER JOIN users AS u ON (p.user_id = u.id)
                    WHERE u.email = auth.jwt() ->> 'email' AND p.permission = 'ADMIN'
                )
            )
            $policy$,
            t
        );
    END LOOP;
END;
$$;

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
        WHERE u.id = saved_opportunities.user_id AND u.email = auth.jwt() ->> 'email'
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM users AS u
        WHERE u.id = saved_opportunities.user_id AND u.email = auth.jwt() ->> 'email'
    )
);

-- Publishes a reviewed bulletin in one transaction. Runs as the caller, so the
-- admin-only policies above decide who may use it. Opportunities are matched on
-- title_key, which keeps their ids and therefore students' saved lists.
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
    new_bulletin_id INT;
    entry JSONB;
    new_opportunity_id INT;
BEGIN
    INSERT INTO opportunity_bulletins (issue, published_on, file_name, entry_count, imported_by)
    VALUES (
        bulletin ->> 'issue',
        (bulletin ->> 'published_on')::DATE,
        bulletin ->> 'file_name',
        jsonb_array_length(entries),
        (bulletin ->> 'imported_by')::INT
    )
    ON CONFLICT (issue) DO UPDATE SET
        published_on = EXCLUDED.published_on,
        file_name = EXCLUDED.file_name,
        entry_count = EXCLUDED.entry_count,
        imported_by = EXCLUDED.imported_by,
        imported_at = CURRENT_TIMESTAMP
    RETURNING id INTO new_bulletin_id;

    FOR entry IN SELECT * FROM jsonb_array_elements(entries)
    LOOP
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

        DELETE FROM opportunity_category_links WHERE opportunity_id = new_opportunity_id;
        INSERT INTO opportunity_category_links (opportunity_id, category_id)
        SELECT new_opportunity_id, value::INT
        FROM jsonb_array_elements_text(entry -> 'category_ids');

        DELETE FROM opportunity_eligibility_links WHERE opportunity_id = new_opportunity_id;
        INSERT INTO opportunity_eligibility_links (opportunity_id, eligibility_id)
        SELECT new_opportunity_id, value::INT
        FROM jsonb_array_elements_text(entry -> 'eligibility_ids');
    END LOOP;

    UPDATE opportunities SET archived = true WHERE id = ANY(archive_ids);

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
