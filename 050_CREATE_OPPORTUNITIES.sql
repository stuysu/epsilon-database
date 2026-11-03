-- Opportunities module: replaces the standalone opportunities.stuysu.org database.

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

CREATE TABLE opportunities (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    date_text TEXT NULL,
    location TEXT NULL,
    cost INT NULL CHECK (cost >= 0), -- NULL means "check description"
    offers_stipend BOOLEAN DEFAULT false NOT NULL,
    deadline DATE NULL, -- NULL means rolling basis; ends 23:59:59 Eastern
    link TEXT NULL,
    archived BOOLEAN DEFAULT false NOT NULL, -- manual; past deadlines count as archived automatically
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

-- Categories carried over from opportunities.stuysu.org.
INSERT INTO opportunity_categories (name, position) VALUES
    ('Academic Programs', 1),
    ('Business and Jobs', 2),
    ('Community Service', 3),
    ('Leadership, Government, International', 4),
    ('Museum, Art, Design', 5),
    ('Parks, Zoo, Nature', 6),
    ('Engineering, Math, Computer Science', 7),
    ('Medical, Life Sciences', 8),
    ('Theater, Music, Writing, Videos', 9),
    ('Contests, Competitions', 10),
    ('Additional Links and Resources', 11),
    ('Scholarships', 12);

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
