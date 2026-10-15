-- CheckMate: teacher module (combined migration)
-- File: 002_teacher_module.sql
--
-- This is the old 002, 003, 004 and 005 joined together, in the same order and
-- with the same SQL. Each part keeps its own BEGIN/COMMIT, so the result is
-- identical to running the four files one after another.
--
-- USE ON A NEW, EMPTY DATABASE ONLY (after 001_initial_schema.sql).
-- Do NOT run it on a database where 002 to 005 were already applied: part 1
-- adds columns and indexes without IF NOT EXISTS and will fail.
-- Do NOT keep the four old files next to this one in a folder that is run
-- automatically, or the same changes would be applied twice.


-- ============================================================
-- PART 1 of 4: teacher management (was 002_teacher_management.sql)
-- ============================================================

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


-- ============================================================
-- PART 2 of 4: teaching assignments (was 003_teaching_assignments.sql)
-- ============================================================

-- CheckMate
-- Teaching assignments (Subject + Section) and year levels
-- Migration: 003_teaching_assignments.sql
--
-- A row in "classes" is already one Subject + Section offering (students and
-- exams hang off it), so it IS the teaching assignment:
--     classes.teacher_id  = the teacher who teaches that subject in that section
-- This migration adds (1) a year level and (2) a database-level guarantee that
-- the same Subject + Section can never exist twice, so it can never belong to
-- two teachers.

BEGIN;

-- ============================================================
-- 1. YEAR LEVEL
-- ============================================================

ALTER TABLE classes
    ADD COLUMN IF NOT EXISTS year_level SMALLINT
        CHECK (year_level BETWEEN 1 AND 6);

-- Best-effort backfill from the first digit in the section name
-- ("BSIT 1-A" -> 1, "BSIT-3A" -> 3). Sections with no digit stay NULL.
UPDATE classes
SET year_level = substring(section from '[0-9]')::smallint
WHERE year_level IS NULL
  AND substring(section from '[0-9]') ~ '^[1-6]$';


-- ============================================================
-- 2. ONE OFFERING PER SUBJECT + SECTION
-- Refuse loudly if duplicates already exist, instead of guessing
-- which row to keep.
-- ============================================================

DO $$
DECLARE
    dup TEXT;
BEGIN
    SELECT string_agg(
               format('subject_id %s / "%s" (%s rows)', subject_id, sec, n),
               '; '
           )
    INTO dup
    FROM (
        SELECT subject_id,
               LOWER(section) AS sec,
               COUNT(*) AS n
        FROM classes
        GROUP BY subject_id,
                 LOWER(section),
                 COALESCE(school_year, ''),
                 COALESCE(semester, '')
        HAVING COUNT(*) > 1
    ) d;

    IF dup IS NOT NULL THEN
        RAISE EXCEPTION
            'Duplicate Subject + Section classes exist: %. Merge or delete the duplicates in the Classes screen/database, then run this migration again.',
            dup;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_classes_subject_section
    ON classes (
        subject_id,
        LOWER(section),
        COALESCE(school_year, ''),
        COALESCE(semester, '')
    );

COMMIT;


-- ============================================================
-- PART 3 of 4: teacher profile fields (was 004_teacher_profile_fields.sql)
-- ============================================================

-- CheckMate
-- Teacher profile fields: structured name, Teacher ID No., department,
-- institutional email rules
-- Migration: 004_teacher_profile_fields.sql
--
-- Requires 002 and 003 to be applied already. Does not touch them.
--
-- Existing teachers are NOT given invented values: their new columns stay
-- NULL until an administrator completes their profile in the Teachers screen
-- (Edit). Their current email/username keep working until then.

BEGIN;

-- ============================================================
-- 1. NEW COLUMNS (users.name stays as the full display name)
-- ============================================================

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS first_name    VARCHAR(100),
    ADD COLUMN IF NOT EXISTS middle_name   VARCHAR(100),
    ADD COLUMN IF NOT EXISTS last_name     VARCHAR(100),
    ADD COLUMN IF NOT EXISTS teacher_id_no VARCHAR(30),
    ADD COLUMN IF NOT EXISTS department    VARCHAR(100);


-- ============================================================
-- 2. UNIQUENESS (case-insensitive)
-- ============================================================

-- Refuse loudly instead of failing half-way if two accounts already differ
-- only by upper/lower case in their email.
DO $$
DECLARE
    dup TEXT;
BEGIN
    SELECT string_agg(e, ', ')
    INTO dup
    FROM (
        SELECT LOWER(email) AS e
        FROM users
        GROUP BY LOWER(email)
        HAVING COUNT(*) > 1
    ) d;

    IF dup IS NOT NULL THEN
        RAISE EXCEPTION
            'Accounts with the same email (ignoring upper/lower case) exist: %. Fix them, then run this migration again.',
            dup;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_users_email_lower
    ON users (LOWER(email));

-- Admins and not-yet-completed legacy teachers have NULL and are ignored.
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_teacher_id_no_lower
    ON users (LOWER(teacher_id_no))
    WHERE teacher_id_no IS NOT NULL;


-- ============================================================
-- 3. RULES THE DATABASE ENFORCES BY ITSELF
-- ============================================================

ALTER TABLE users
    DROP CONSTRAINT IF EXISTS chk_users_teacher_id_not_blank;

ALTER TABLE users
    ADD CONSTRAINT chk_users_teacher_id_not_blank
    CHECK (teacher_id_no IS NULL OR BTRIM(teacher_id_no) <> '');

-- Any account that has a Teacher ID must use the institutional domain.
ALTER TABLE users
    DROP CONSTRAINT IF EXISTS chk_users_teacher_email_domain;

ALTER TABLE users
    ADD CONSTRAINT chk_users_teacher_email_domain
    CHECK (
        teacher_id_no IS NULL
        OR LOWER(email) LIKE '%@sti.checkmate.com'
    );

COMMIT;


-- ============================================================
-- PART 4 of 4: automatic Teacher IDs (was 005_auto_teacher_id.sql)
-- ============================================================

-- CheckMate: automatically allocated, immutable Teacher IDs.
-- Run ONCE after migration 004 and BEFORE deploying the matching backend.
BEGIN;

CREATE TABLE IF NOT EXISTS teacher_id_counters (
  year INTEGER PRIMARY KEY CHECK (year BETWEEN 2000 AND 9999),
  last_number INTEGER NOT NULL CHECK (last_number BETWEEN 1 AND 9999)
);

-- Resume after any already-issued formatted IDs; never reset a year's counter.
INSERT INTO teacher_id_counters (year, last_number)
SELECT substring(teacher_id_no FROM 4 FOR 4)::INTEGER,
       MAX(substring(teacher_id_no FROM 9 FOR 4)::INTEGER)
FROM users
WHERE teacher_id_no ~ '^CM-[0-9]{4}-[0-9]{4}$'
GROUP BY substring(teacher_id_no FROM 4 FOR 4)::INTEGER
ON CONFLICT (year) DO UPDATE
  SET last_number = GREATEST(teacher_id_counters.last_number, EXCLUDED.last_number);

-- Existing numeric IDs are retained for backwards compatibility.
ALTER TABLE users DROP CONSTRAINT IF EXISTS chk_users_teacher_id_format;
ALTER TABLE users ADD CONSTRAINT chk_users_teacher_id_format CHECK (
  teacher_id_no IS NULL OR
  teacher_id_no ~ '^(CM-[0-9]{4}-(000[1-9]|00[1-9][0-9]|0[1-9][0-9]{2}|[1-9][0-9]{3})|[0-9]{3,20})$'
);

-- Enforce immutability even if a future API mistakenly tries to change an ID.
CREATE OR REPLACE FUNCTION checkmate_teacher_id_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.teacher_id_no IS NOT NULL
     AND NEW.teacher_id_no IS DISTINCT FROM OLD.teacher_id_no THEN
    RAISE EXCEPTION 'Teacher ID cannot be changed once assigned.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_teacher_id_immutable ON users;
CREATE TRIGGER trg_teacher_id_immutable
BEFORE UPDATE OF teacher_id_no ON users
FOR EACH ROW EXECUTE FUNCTION checkmate_teacher_id_immutable();

COMMIT;
