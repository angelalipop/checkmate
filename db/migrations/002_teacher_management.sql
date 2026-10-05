BEGIN;


ALTER TABLE users
    ADD COLUMN username VARCHAR(100),
    ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN subject_id BIGINT REFERENCES subjects(id) ON DELETE SET NULL;

WITH base AS (
    SELECT
        id,
        COALESCE(
            NULLIF(
                regexp_replace(
                    lower(split_part(email, '@', 1)),
                    '[^a-z0-9._-]', '', 'g'
                ),
                ''
            ),
            'user'
        ) AS name_part
    FROM users
),
ranked AS (
    SELECT
        id,
        name_part,
        row_number() OVER (PARTITION BY name_part ORDER BY id) AS rn
    FROM base
)
UPDATE users u
SET username = CASE
        WHEN r.rn = 1 THEN r.name_part
        ELSE r.name_part || '_' || u.id
    END
FROM ranked r
WHERE r.id = u.id;

ALTER TABLE users
    ALTER COLUMN username SET NOT NULL;

CREATE UNIQUE INDEX uq_users_username_lower
    ON users (lower(username));

CREATE INDEX idx_users_role
    ON users(role);


ALTER TABLE classes
    ALTER COLUMN teacher_id DROP NOT NULL;

ALTER TABLE classes
    DROP CONSTRAINT IF EXISTS classes_teacher_id_fkey;

ALTER TABLE classes
    ADD CONSTRAINT classes_teacher_id_fkey
    FOREIGN KEY (teacher_id) REFERENCES users(id) ON DELETE SET NULL;

COMMIT;
