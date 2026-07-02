-- strom update 002: users and user-owned objects

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS app_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_objects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_app_users_name_lower ON app_users (lower(name));
CREATE INDEX IF NOT EXISTS idx_user_objects_user ON user_objects(user_id);

INSERT INTO app_users (name)
SELECT 'Standardnutzer'
WHERE NOT EXISTS (SELECT 1 FROM app_users);

INSERT INTO user_objects (user_id, name)
SELECT u.id, 'Mein Haus'
FROM app_users u
WHERE NOT EXISTS (
    SELECT 1 FROM user_objects o WHERE o.user_id = u.id
);

ALTER TABLE projects
    ADD COLUMN IF NOT EXISTS object_id UUID REFERENCES user_objects(id) ON DELETE CASCADE;

WITH first_object AS (
    SELECT id FROM user_objects ORDER BY created_at LIMIT 1
)
UPDATE projects
SET object_id = (SELECT id FROM first_object)
WHERE object_id IS NULL;

DO $$
DECLARE
    obj UUID;
    proj UUID;
    house UUID;
BEGIN
    FOR obj IN
        SELECT o.id
        FROM user_objects o
        WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.object_id = o.id)
    LOOP
        INSERT INTO projects (object_id, name, description)
        VALUES (obj, 'Startprojekt', 'Automatisch angelegtes Startprojekt')
        RETURNING id INTO proj;

        INSERT INTO houses (project_id, name)
        VALUES (proj, 'Wohnhaus')
        RETURNING id INTO house;

        INSERT INTO floors (house_id, name, level_index, elevation_m, height_m)
        VALUES (house, 'EG', 0, 0, 2.5);
    END LOOP;
END $$;

DO $$
DECLARE
    proj UUID;
    house UUID;
BEGIN
    FOR proj IN
        SELECT p.id
        FROM projects p
        WHERE NOT EXISTS (SELECT 1 FROM houses h WHERE h.project_id = p.id)
    LOOP
        INSERT INTO houses (project_id, name)
        VALUES (proj, 'Wohnhaus')
        RETURNING id INTO house;

        INSERT INTO floors (house_id, name, level_index, elevation_m, height_m)
        VALUES (house, 'EG', 0, 0, 2.5);
    END LOOP;
END $$;

DO $$
DECLARE
    house UUID;
BEGIN
    FOR house IN
        SELECT h.id
        FROM houses h
        WHERE NOT EXISTS (SELECT 1 FROM floors f WHERE f.house_id = h.id)
    LOOP
        INSERT INTO floors (house_id, name, level_index, elevation_m, height_m)
        VALUES (house, 'EG', 0, 0, 2.5);
    END LOOP;
END $$;

UPDATE projects
SET object_id = (SELECT id FROM user_objects ORDER BY created_at LIMIT 1)
WHERE object_id IS NULL;

ALTER TABLE projects
    ALTER COLUMN object_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_projects_object ON projects(object_id);

